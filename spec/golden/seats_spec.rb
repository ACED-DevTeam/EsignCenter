# frozen_string_literal: true

# Seats: who is in an account, what each of them costs, and every way that
# number can change (Session 7 Phase B, D43/D50).
#
# The rules this file protects:
#
#   * A seat is never promised before it exists. On a paid account with no
#     free seat the admin is shown what Stripe will charge TODAY, and nothing
#     is reserved until the money has actually moved.
#   * Occupancy counts people AND the invitations holding a seat for people
#     who have not arrived yet, and never counts a read-only member.
#   * Seats come back down at renewal, never below occupancy, and never below
#     one — `proration_behavior: 'none'`, because a reduction earns no
#     mid-cycle refund (D43).
#   * An address that already belongs to another account is an OFFER, not an
#     error (D50): accepting moves that person and their documents into the
#     team, and their old account is archived rather than deleted.
#   * An account can never lose its last administrator.
#
# Stripe is never really called: every request is a WebMock stub answered with
# a real CLI capture whose quantity is overridden (spec/support/
# stripe_test_account.rb). An example that stubs nothing proves no call was
# made at all, because WebMock fails an unstubbed request.
RSpec.describe 'Seats and invitations', type: :request do
  include_context 'with a Stripe test account'

  let(:account) { create(:account) }
  let!(:admin) { create(:user, account:) }
  let(:deliveries) { ActionMailer::Base.deliveries }
  # The item id of the fixture capture: the seat flow changes THIS item.
  let(:fixture_item) { 'si_VBqHaGFRPKUSpk' }

  before do
    deliveries.clear
    sign_in(admin)
  end

  # A fresh integration session is the only reliable actor switch (see
  # spec/golden/gating_spec.rb).
  def act_as(user)
    sign_out(:user)
    reset!
    sign_in(user)
  end

  def anonymous!
    sign_out(:user)
    reset!
  end

  def unique_email
    "seat-#{SecureRandom.hex(4)}@example.com"
  end

  # A subscription this app really bills through Stripe: live, on our price,
  # with the item the seat flow has to change.
  def stripe_paid!(record, seats:, subscription_id: subscription_a, customer_id: customer_a)
    create(:account_subscription, account: record, access_state: 'active', status: 'active',
                                  stripe_status: 'active', quantity: seats,
                                  stripe_customer_id: customer_id, stripe_subscription_id: subscription_id,
                                  stripe_item_id: fixture_item, stripe_price_id: fixture_price,
                                  current_period_end: 20.days.from_now)
  end

  def invite(email, role: User::ADMIN_ROLE)
    post '/users', params: { user: { email:, first_name: 'New', last_name: 'Person', role: } }
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  # Every idempotency key a seat purchase has been sent under, in order.
  def seat_add_keys
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys.filter_map do |signature|
      key = signature.headers.to_h['Idempotency-Key'].to_s

      key if key.start_with?('seat-add:')
    end
  end

  # The signed offer the confirm screen carries. Reading it out of the page is
  # the point: the browser hands back exactly what the server minted, and
  # nothing else on that form decides what is bought.
  def offer_token
    doc.at('input[name="offer"]')['value']
  end

  describe 'occupancy' do
    it 'counts people and pending invitations, and never counts a read-only member' do
      expect(Accounts.seat_occupancy(account)).to eq(1)
      expect(Accounts.users_count(account)).to eq(1)

      create(:account_invite, account:)

      expect(Accounts.users_count(account)).to eq(2)

      # An invitation that has lapsed holds nothing.
      create(:account_invite, :expired, account:)

      expect(Accounts.users_count(account)).to eq(2)

      member = create(:user, account:)

      expect(Accounts.users_count(account)).to eq(3)

      member.update!(read_only_at: Time.current)

      expect(Accounts.users_count(account)).to eq(2)

      # An API-only user has never been a seat.
      create(:user, account:, role: 'integration')

      expect(Accounts.users_count(account)).to eq(2)
    end

    # A seat purchase Stripe parked for a card step is not a seat: nothing was
    # charged, the subscription still bills the old number, and the row exists
    # only so that finishing the step can finish the job (checkpoint 7, B1).
    # If it counted, the account would be one person over its plan for a day
    # on the strength of a payment that may never happen.
    it 'does not count a parked purchase as occupancy' do
      create(:account_invite, account:, payment_pending_until: 6.hours.from_now,
                              pending_quantity: 2, expires_at: 6.hours.from_now)

      expect(Accounts.users_count(account)).to eq(1)
      expect(AccountInvite.pending.count).to eq(0)
      expect(AccountInvite.payment_pending.count).to eq(1)
    end
  end

  describe 'inviting' do
    it 'refuses a second person on the free plan, exactly as before' do
      expect { invite(unique_email) }.not_to change(AccountInvite, :count)

      expect(response).to redirect_to('/settings/users')
      expect(flash[:alert]).to eq(I18n.t('seat_limit_free'))
      expect(User.where(account:).count).to eq(1)
    end

    # No Stripe stub anywhere in this example: a free seat costs nothing to
    # fill, so nothing may be asked of Stripe.
    it 'reserves a free seat with an invitation, sends the mail, and never calls Stripe', sidekiq: :inline do
      stripe_paid!(account, seats: 2)
      email = unique_email

      expect { invite(email, role: User::EDITOR_ROLE) }.to change(AccountInvite, :count).by(1)

      invite_row = AccountInvite.sole

      expect(invite_row.email).to eq(email)
      expect(invite_row.role).to eq(User::EDITOR_ROLE)
      expect(invite_row.invited_by).to eq(admin)
      expect(invite_row).to be_pending
      expect(invite_row.token_digest).to be_present
      expect(Accounts.users_count(account)).to eq(2)

      mail = deliveries.sole

      expect(mail.to).to eq([email])
      expect(mail.subject).to include(account.name)
      # The link carries the raw token, which the row itself never holds.
      expect(body_of(mail)).to include('/invites/')
    end

    it 'refuses somebody who is already in the account, and somebody already invited' do
      stripe_paid!(account, seats: 5)

      invite(admin.email)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('already_exists'))

      email = unique_email
      invite(email)

      expect { invite(email) }.not_to change(AccountInvite, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('invite_already_pending'))
    end

    # An operator-granted plan has no Stripe item to change, so the old
    # refusal is still the honest answer there.
    it 'refuses a full account whose plan was granted by hand' do
      create(:account_subscription, account:, access_state: 'active', status: 'manual', quantity: 1)

      expect { invite(unique_email) }.not_to change(AccountInvite, :count)

      expect(flash[:alert]).to eq(I18n.t('seat_limit_paid', count: 1))
    end

    it 'creates the user outright on an internal account, with no invitation and no seat limit' do
      internal = create(:account, :internal)
      act_as(create(:user, account: internal))

      expect { 3.times { invite(unique_email) } }.to change(User, :count).by(3)
      expect(AccountInvite.count).to eq(0)
    end
  end

  describe 'buying a seat' do
    before { stripe_paid!(account, seats: 1) }

    it 'prices the extra seat before anything is reserved' do
      stub_invoice_preview(amount_cents: 634)

      expect { invite('new-hire@example.com') }.not_to change(AccountInvite, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('new-hire@example.com')
      expect(doc.at('[data-seat-amount]').text.strip).to eq('$6.34')
      expect(doc.at('[data-seat-quantity]').text.strip).to eq('2')

      expect(WebMock).to(
        have_requested(:post, 'https://api.stripe.com/v1/invoices/create_preview').with do |req|
          req.body.include?('subscription_details[items][0][quantity]=2') &&
            req.body.include?('subscription_details[proration_behavior]=always_invoice')
        end
      )
    end

    # H1: the preview and the charge must price the SAME slice of the billing
    # period. Left to Stripe's "now", a renewal falling between the screen and
    # the click invoices a whole period the customer never agreed to.
    it 'prices the preview and the charge from one pinned instant' do
      stub_invoice_preview(amount_cents: 634)
      stub_subscription_update(subscription_a, quantity: 2)
      stub_subscription_reread(subscription_a, quantity: 2)

      invite('new-hire@example.com')

      offer = Rails.application.message_verifier(:seat_add).verify(offer_token).with_indifferent_access
      pinned = offer[:proration_date].to_i

      expect(pinned).to be_positive

      post '/account_invites', params: { offer: offer_token }

      expect(WebMock).to(
        have_requested(:post, 'https://api.stripe.com/v1/invoices/create_preview').with do |req|
          req.body.include?("subscription_details[proration_date]=#{pinned}")
        end.twice
      )
      expect(WebMock).to(
        have_requested(:post, "https://api.stripe.com/v1/subscriptions/#{subscription_a}").with do |req|
          req.body.include?("proration_date=#{pinned}")
        end
      )
    end

    it 'charges first and reserves second, then sends the invitation', sidekiq: :inline do
      stub_invoice_preview(amount_cents: 634)
      stub_subscription_update(subscription_a, quantity: 2)
      stub_subscription_reread(subscription_a, quantity: 2)

      invite('new-hire@example.com')

      expect { post '/account_invites', params: { offer: offer_token } }
        .to change(AccountInvite, :count).by(1)

      expect(response).to redirect_to('/settings/users')
      expect(flash[:notice]).to eq(I18n.t('user_has_been_invited'))

      expect(WebMock).to(
        have_requested(:post, "https://api.stripe.com/v1/subscriptions/#{subscription_a}").with do |req|
          req.body.include?('items[0][quantity]=2') &&
            req.body.include?('proration_behavior=always_invoice') &&
            req.body.include?('payment_behavior=pending_if_incomplete') &&
            req.headers['Idempotency-Key'].to_s.start_with?('seat-add:')
        end
      )

      # The row is re-read from Stripe rather than trusted to know what it
      # just asked for.
      expect(account.account_subscription.reload.quantity).to eq(2)
      expect(AccountInvite.sole.email).to eq('new-hire@example.com')
      expect(Accounts.users_count(account)).to eq(2)
      expect(deliveries.map(&:to).flatten).to include('new-hire@example.com')
    end

    # Stripe parks a change it cannot charge for (3-D Secure) as a
    # `pending_update`. The seat is not bought, so nothing is promised — but
    # the purchase is REMEMBERED, parked exactly like Stripe's own update
    # (checkpoint 7, B1), so that finishing the card step finishes the job.
    it 'promises no seat when Stripe parks the change for a payment step, and mails nobody' do
      # Stripe's own deadline for the card step, which becomes the parked
      # invitation's clock.
      parked_until = 20.hours.from_now.change(usec: 0)

      stub_invoice_preview(amount_cents: 634)
      stub_subscription_update(subscription_a, quantity: 2,
                                               overrides: { 'pending_update' =>
                                                              { 'expires_at' => parked_until.to_i } })

      invite('new-hire@example.com')

      post '/account_invites', params: { offer: offer_token }

      expect(response).to redirect_to('/settings/users')
      expect(flash[:alert]).to eq(I18n.t('seat_add_needs_payment_action', email: 'new-hire@example.com'))
      expect(account.account_subscription.reload.quantity).to eq(1)

      parked = AccountInvite.sole

      # Parked is not pending: it holds no seat and no accept link for it has
      # ever left this building. It IS listed on the users page, as Awaiting
      # payment with a Cancel next to it (checkpoint 7, P5), which is the only
      # way an admin can change their mind before Stripe's deadline.
      expect(parked).not_to be_pending
      expect(parked).to be_payment_pending
      expect(parked.pending_quantity).to eq(2)
      expect(parked.payment_pending_until).to eq(parked_until)
      expect(Accounts.users_count(account)).to eq(1)
      expect(deliveries).to be_empty
    end

    it 'refuses an offer whose seat count is no longer the one that was priced' do
      stub_invoice_preview(amount_cents: 634)

      invite('new-hire@example.com')

      token = offer_token

      # Somebody bought a seat in another tab: the quoted amount is now a lie.
      account.account_subscription.update!(quantity: 2)

      expect { post '/account_invites', params: { offer: token } }.not_to change(AccountInvite, :count)

      expect(flash[:alert]).to eq(I18n.t('seat_offer_stale'))
    end

    # No preview is stubbed here, so WebMock refuses any call at all: an
    # address that could never be saved must not cost anybody $10.
    it 'never prices a seat for an address that could not be saved anyway' do
      expect { invite('not-an-address') }.not_to change(AccountInvite, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('is invalid')
    end

    it 'refuses an offer that was not signed by this server' do
      expect { post '/account_invites', params: { offer: 'not-a-real-offer' } }
        .not_to change(AccountInvite, :count)

      expect(flash[:alert]).to eq(I18n.t('seat_offer_expired'))
    end

    it 'refuses an offer that has gone stale on the clock' do
      stub_invoice_preview(amount_cents: 634)

      invite('new-hire@example.com')

      token = offer_token

      travel(UsersController::SEAT_OFFER_TTL + 1.minute) do
        expect { post '/account_invites', params: { offer: token } }.not_to change(AccountInvite, :count)

        expect(flash[:alert]).to eq(I18n.t('seat_offer_expired'))
      end
    end

    # An offer is signed by THIS server, so its price cannot be edited in the
    # form — but a signature says nothing about who it was minted for. The
    # account it names is inside the signature and is checked against the
    # account making the request, or one company's admin could hand another
    # company's subscription a seat (checkpoint 7, B3). Nothing is stubbed
    # after the preview, so WebMock proves Stripe was never asked.
    it 'refuses an offer minted for a different account' do
      other_account = create(:account)
      other_admin = create(:user, account: other_account)

      stripe_paid!(other_account, seats: 1, subscription_id: subscription_b, customer_id: customer_b)

      stub_invoice_preview(amount_cents: 634)

      invite('new-hire@example.com')

      token = offer_token

      act_as(other_admin)

      expect { post '/account_invites', params: { offer: token } }.not_to change(AccountInvite, :count)

      expect(flash[:alert]).to eq(I18n.t('seat_offer_expired'))
      expect(other_account.account_subscription.reload.quantity).to eq(1)
      expect(account.account_subscription.reload.quantity).to eq(1)
      expect(WebMock).not_to have_requested(:post, "https://api.stripe.com/v1/subscriptions/#{subscription_a}")
      expect(WebMock).not_to have_requested(:post, "https://api.stripe.com/v1/subscriptions/#{subscription_b}")
    end
  end

  # Review batch 1, F5: what the confirm click must be sure of before, and
  # after, it puts money on somebody's card.
  describe 'buying a seat honestly' do
    before { stripe_paid!(account, seats: 1) }

    def offer_for(email)
      stub_invoice_preview(amount_cents: 634)
      invite(email)

      offer_token
    end

    # The key used to name the ADDRESS, so inviting somebody, cancelling and
    # inviting them again reused it: Stripe replayed the first answer,
    # charged nothing, left the quantity alone — and an invitation was
    # reserved against a seat nobody had bought.
    it 'keys each purchase to the click, not to the address' do
      stub_subscription_update(subscription_a, quantity: 2)
      stub_subscription_reread(subscription_a, quantity: 2)

      post '/account_invites', params: { offer: offer_for('new-hire@example.com') }

      first_key = seat_add_keys.last

      stub_subscription_update(subscription_a, quantity: 1)
      stub_subscription_reread(subscription_a, quantity: 1)

      delete "/account_invites/#{AccountInvite.sole.id}"

      stub_subscription_update(subscription_a, quantity: 2)
      stub_subscription_reread(subscription_a, quantity: 2)

      post '/account_invites', params: { offer: offer_for('new-hire@example.com') }

      expect(seat_add_keys.uniq.size).to eq(2)
      expect(seat_add_keys.last).not_to eq(first_key)
    end

    # Stripe answering 200 is not the same as Stripe changing anything: an
    # idempotent replay answers with the OLD subscription.
    it 'reserves nothing when the subscription comes back still billing the old number' do
      token = offer_for('new-hire@example.com')
      stub_subscription_update(subscription_a, quantity: 1)
      stub_subscription_reread(subscription_a, quantity: 1)

      expect { post '/account_invites', params: { offer: token } }.not_to change(AccountInvite, :count)

      expect(flash[:alert]).to eq(I18n.t('seat_offer_stale'))
      expect(account.account_subscription.reload.quantity).to eq(1)
    end

    # A renewal can fall inside the quarter-hour an offer is good for, and
    # then the prorated amount is a whole period different from the one that
    # was agreed to.
    it 'refuses to charge materially more than the customer was shown' do
      token = offer_for('new-hire@example.com')

      stub_invoice_preview(amount_cents: 1000)

      expect { post '/account_invites', params: { offer: token } }.not_to change(AccountInvite, :count)

      expect(flash[:alert]).to eq(I18n.t('seat_add_price_changed'))
      expect(WebMock).not_to have_requested(:post, "https://api.stripe.com/v1/subscriptions/#{subscription_a}")
      expect(account.account_subscription.reload.quantity).to eq(1)
    end

    # Stripe prorates by the SECOND: the amount ticks down while somebody
    # reads the confirm screen, and rounding can put it a penny the other way.
    # Refusing on an exact mismatch turned an honest slow click into "please
    # try again" every time.
    it 'still buys the seat when the fresh amount has drifted by a penny either way' do
      token = offer_for('new-hire@example.com')
      stub_subscription_update(subscription_a, quantity: 2)
      stub_subscription_reread(subscription_a, quantity: 2)

      # A second of proration cheaper, and a penny of rounding dearer.
      stub_invoice_preview(amount_cents: 633)

      expect { post '/account_invites', params: { offer: token } }.to change(AccountInvite, :count).by(1)

      expect(flash[:notice]).to eq(I18n.t('user_has_been_invited'))

      token = offer_for('second-hire@example.com')
      stub_subscription_update(subscription_a, quantity: 3)
      stub_subscription_reread(subscription_a, quantity: 3)
      stub_invoice_preview(amount_cents: 636)

      expect { post '/account_invites', params: { offer: token } }.to change(AccountInvite, :count).by(1)
    end

    # A role that stopped being a role between the offer and the click: the
    # invitation cannot be written, so nothing may be charged for it. It used
    # to come out of the door as a 500 (ActiveModel::ValidationError, which is
    # not the ActiveRecord flavour the action rescued).
    it 'refuses an offer whose role is no longer a role, before the card is touched' do
      row = account.account_subscription
      offer = { 'account_id' => account.id, 'email' => 'new-hire@example.com', 'role' => 'superadmin',
                'quantity_after' => 2, 'amount_cents' => 634, 'currency' => 'usd',
                'subscription_id' => row.stripe_subscription_id, 'item_id' => row.stripe_item_id,
                'nonce' => SecureRandom.hex(8) }
      token = Rails.application.message_verifier(:seat_add).generate(offer, expires_in: 15.minutes)

      expect { post '/account_invites', params: { offer: token } }.not_to change(AccountInvite, :count)

      expect(response).to redirect_to('/settings/users')
      expect(flash[:alert]).to be_present
      expect(WebMock).not_to have_requested(:post, "https://api.stripe.com/v1/subscriptions/#{subscription_a}")
      expect(row.reload.quantity).to eq(1)
    end

    # The card HAS been charged by the time the invitation is written. If it
    # will not save, "nothing was reserved" is a lie, and a person has to be
    # put on it.
    it 'tells the truth when the seat was charged but the invitation would not save', sidekiq: :inline do
      token = offer_for('new-hire@example.com')
      stub_subscription_update(subscription_a, quantity: 2)
      stub_subscription_reread(subscription_a, quantity: 2)

      # Two invitations minting the same token: the second one hits the unique
      # index the moment it is inserted, and it is inserted after the charge.
      allow(SecureRandom).to receive(:urlsafe_base64).and_return('one-and-only-token')
      create(:account_invite, account: create(:account))

      expect { post '/account_invites', params: { offer: token } }.not_to change(AccountInvite, :count)

      expect(flash[:alert]).to eq(I18n.t('seat_add_charged_without_invite'))
      # The charge stands, and it is the operator's problem now, not a
      # silently swallowed one.
      expect(account.account_subscription.reload.quantity).to eq(2)
      expect(deliveries.map(&:subject).join(' ')).to include('seat charged but invitation not saved')
    end

    # A seat can come free between the quote and the click, and then the
    # customer already owns it (checkpoint 7, B4). The way it happens in
    # practice: somebody is archived while Stripe is unreachable, so the
    # hand-back fails and the subscription goes on billing the higher number.
    # Charging again for a seat that is sitting there paid for is taking money
    # for nothing, so the invitation is simply written into it.
    it 'charges nothing when a seat came free between the quote and the click' do
      row = account.account_subscription
      member = create(:user, account:, role: User::EDITOR_ROLE)
      row.update!(quantity: 2)

      # Quoted while every seat was taken: two people, two seats.
      token = offer_for('new-hire@example.com')

      # The member leaves and Stripe will not take the lower number.
      stub_request(:post, seat_subscription_url(subscription_a))
        .to_return(status: 500, body: { error: { type: 'api_error', message: 'boom' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      delete "/users/#{member.id}"

      expect(member.reload.archived_at).to be_present
      expect(row.reload.quantity).to eq(2)
      expect(Accounts.seat_occupancy(account)).to eq(1)

      # Everything Stripe has been asked so far is forgotten, so what follows
      # is a statement about THIS click and nothing else.
      WebMock::RequestRegistry.instance.reset!

      expect { post '/account_invites', params: { offer: token } }.to change(AccountInvite, :count).by(1)

      expect(response).to redirect_to('/settings/users')
      expect(flash[:notice]).to eq(I18n.t('user_has_been_invited'))
      expect(AccountInvite.sole.email).to eq('new-hire@example.com')
      expect(row.reload.quantity).to eq(2)
      expect(Accounts.seat_occupancy(account)).to eq(2)
      expect(WebMock).not_to have_requested(:post, seat_subscription_url(subscription_a))
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/invoices/create_preview')
    end
  end

  describe 'releasing a seat' do
    # Three people and five seats billed, with one invitation still holding a
    # sixth... no: five seats, three people and one pending invitation is an
    # occupancy of four. When the invitation lapses the account occupies three
    # — and three is what Stripe is told, not four and not one.
    it 'drops the quantity to occupancy when an invitation lapses, and is a no-op on the next tick' do
      create_list(:user, 2, account:)
      row = stripe_paid!(account, seats: 5)
      lapsed = create(:account_invite, account:)
      stub_subscription_update(subscription_a, quantity: 3)
      stub_subscription_reread(subscription_a, quantity: 3)

      expect(Accounts.users_count(account)).to eq(4)

      lapsed.update!(expires_at: 1.hour.ago)

      expect(Accounts.users_count(account)).to eq(3)

      BillingLifecycle.expire_invites!

      expect(WebMock).to(
        have_requested(:post, "https://api.stripe.com/v1/subscriptions/#{subscription_a}").with do |req|
          req.body.include?('items[0][quantity]=3') && req.body.include?('proration_behavior=none')
        end.once
      )
      expect(row.reload.quantity).to eq(3)
      expect(lapsed.reload.released_at).to be_present

      # A second tick has nothing left to hand back.
      BillingLifecycle.expire_invites!

      expect(WebMock).to have_requested(:post, "https://api.stripe.com/v1/subscriptions/#{subscription_a}").once
    end

    it 'never goes below the people who are actually there' do
      create_list(:user, 3, account:)
      row = stripe_paid!(account, seats: 4)
      stub_subscription_update(subscription_a, quantity: 4)
      stub_subscription_reread(subscription_a, quantity: 4)

      # Review batch 1, F2 gave this a three-way answer, because "nothing to
      # hand back" and "Stripe would not take it" have to be told apart: only
      # the second leaves work for the next sweep.
      expect(BillingLifecycle.release_seats!(row)).to eq(:noop)
      expect(WebMock).not_to have_requested(:post, "https://api.stripe.com/v1/subscriptions/#{subscription_a}")
      expect(row.reload.quantity).to eq(4)
    end

    it 'hands the seat back when the admin cancels the invitation' do
      row = stripe_paid!(account, seats: 2)
      invite_row = create(:account_invite, account:)
      stub_subscription_update(subscription_a, quantity: 1)
      stub_subscription_reread(subscription_a, quantity: 1)

      expect { delete "/account_invites/#{invite_row.id}" }.to change { invite_row.reload.revoked_at }.from(nil)

      expect(response).to redirect_to('/settings/users')
      expect(invite_row).not_to be_pending
      expect(row.reload.quantity).to eq(1)
      expect(WebMock).to(
        have_requested(:post, "https://api.stripe.com/v1/subscriptions/#{subscription_a}").with do |req|
          req.body.include?('items[0][quantity]=1') && req.body.include?('proration_behavior=none')
        end
      )
    end

    it 'hands the seat back when a member is removed' do
      member = create(:user, account:, role: User::EDITOR_ROLE)
      row = stripe_paid!(account, seats: 2)
      stub_subscription_update(subscription_a, quantity: 1)
      stub_subscription_reread(subscription_a, quantity: 1)

      delete "/users/#{member.id}"

      expect(member.reload.archived_at).to be_present
      expect(row.reload.quantity).to eq(1)
    end

    # Checkpoint 7, P5. A parked purchase used to have exactly one way out —
    # waiting for Stripe's deadline — even though the code said an admin could
    # cancel it "like any other invitation". Now it is on the users page under
    # Awaiting payment with a Cancel next to it, and cancelling asks Stripe for
    # nothing at all: the quantity never moved, so there is nothing to take
    # back.
    #
    # The subscription bills for TWO seats and only one is occupied (the
    # second member's login was closed), so a hand-back here would really ask
    # Stripe to go down to one — checkpoint 7, V4: at quantity 1 the claim
    # could not fail, because a hand-back would have been a no-op whether or
    # not the code asked for it. Nothing Stripe-side is stubbed and the
    # example asserts zero requests to api.stripe.com, so any outbound call
    # fails it outright.
    it 'lets an admin cancel a parked purchase, and asks Stripe for nothing' do
      row = stripe_paid!(account, seats: 2)
      create(:user, account:, archived_at: Time.current)
      parked = create(:account_invite, account:, email: 'parked@example.com',
                                       payment_pending_until: 20.hours.from_now,
                                       pending_quantity: 2, expires_at: 20.hours.from_now)

      get '/settings/users'

      expect(response.body).to include('parked@example.com')
      expect(doc.at('[data-invite-awaiting-payment="parked@example.com"]').text.strip)
        .to eq(I18n.t('invite_awaiting_payment'))

      # There is nothing to send again: nobody was ever mailed.
      row_html = doc.at('[data-pending-invite="parked@example.com"]')

      expect(row_html.at("form[action='/account_invites/#{parked.id}/resend']")).to be_nil
      expect(row_html.at("form[action='/account_invites/#{parked.id}']")).to be_present

      delete "/account_invites/#{parked.id}"

      expect(response).to redirect_to('/settings/users')
      expect(flash[:notice]).to eq(I18n.t('invitation_has_been_cancelled'))
      expect(parked.reload.revoked_at).to be_present
      expect(parked.released_at).to be_present
      expect(parked).not_to be_payment_pending
      expect(row.reload.quantity).to eq(2)
      expect(deliveries).to be_empty
      expect(Accounts.seat_occupancy(account)).to eq(1)
      expect(WebMock).not_to have_requested(:any, %r{\Ahttps://api\.stripe\.com/})
    end

    # Checkpoint 7, V2. Between Stripe's deadline for the card step and the
    # hourly sweep that settles the row, a parked purchase used to render as
    # an ordinary invitation: a "Pending · expires" line, a Resend button that
    # answered 404, and a Cancel that reported success and changed nothing. It
    # is the same parked purchase it always was — it simply cannot be finished
    # any more — so the page says so, offers only Cancel, and Cancel really
    # settles it.
    it 'settles a parked purchase whose payment deadline passed before the sweep ran' do
      row = stripe_paid!(account, seats: 2)
      parked = create(:account_invite, account:, email: 'lapsed@example.com',
                                       payment_pending_until: 30.minutes.ago,
                                       pending_quantity: 2, expires_at: 20.hours.from_now)

      get '/settings/users'

      row_html = doc.at('[data-pending-invite="lapsed@example.com"]')

      expect(row_html).to be_present
      expect(doc.at('[data-invite-payment-expired="lapsed@example.com"]').text.strip)
        .to eq(I18n.t('invite_payment_step_expired'))
      expect(doc.at('[data-invite-awaiting-payment="lapsed@example.com"]')).to be_nil

      # Nothing was ever sent, so there is nothing to send again — on the page
      # or at the door.
      expect(row_html.at("form[action='/account_invites/#{parked.id}/resend']")).to be_nil
      expect(row_html.at("form[action='/account_invites/#{parked.id}']")).to be_present
      expect { post "/account_invites/#{parked.id}/resend" }.to raise_error(ActiveRecord::RecordNotFound)

      delete "/account_invites/#{parked.id}"

      expect(response).to redirect_to('/settings/users')
      expect(flash[:notice]).to eq(I18n.t('invitation_has_been_cancelled'))
      expect(parked.reload.revoked_at).to be_present
      expect(parked.released_at).to be_present
      expect(row.reload.quantity).to eq(2)
      expect(deliveries).to be_empty
      expect(WebMock).not_to have_requested(:any, %r{\Ahttps://api\.stripe\.com/})
    end

    it 'refuses to resend a parked purchase, because nothing was ever sent' do
      stripe_paid!(account, seats: 1)
      parked = create(:account_invite, account:, payment_pending_until: 20.hours.from_now,
                                       pending_quantity: 2, expires_at: 20.hours.from_now)

      expect { post "/account_invites/#{parked.id}/resend" }.to raise_error(ActiveRecord::RecordNotFound)

      expect(parked.reload).to be_payment_pending
      expect(deliveries).to be_empty
    end

    it 'sends the invitation again on a fresh token and leaves the seat alone', sidekiq: :inline do
      stripe_paid!(account, seats: 2)
      invite_row = create(:account_invite, account:)
      original_digest = invite_row.token_digest

      post "/account_invites/#{invite_row.id}/resend"

      expect(response).to redirect_to('/settings/users')
      expect(invite_row.reload.token_digest).not_to eq(original_digest)
      expect(invite_row).to be_pending
      expect(deliveries.map(&:to).flatten).to include(invite_row.email)
    end
  end

  # Review batch 1, F2. Every way a seat count can drift upward and stay
  # there, and the two things that bring it back: the release that runs the
  # moment Stripe tells us the quantity, and the hourly backstop under it.
  describe 'a seat count that drifted upward' do
    # The other half of the parked purchase (checkpoint 7, B1): the customer
    # DID finish the card step, so the seat they paid for is theirs and the
    # invitation goes out. This used to be the worst outcome in the whole seat
    # flow — the proration was charged, the seat was handed straight back with
    # no credit, and nobody was ever invited.
    it 'writes and sends the invitation when the parked seat is finally paid' do
      row = stripe_paid!(account, seats: 1)
      stub_invoice_preview(amount_cents: 634)
      stub_subscription_update(subscription_a, quantity: 2,
                                               overrides: { 'pending_update' =>
                                                              { 'expires_at' => 20.hours.from_now.to_i } })

      invite('new-hire@example.com')

      post '/account_invites', params: { offer: offer_token }

      expect(flash[:alert]).to eq(I18n.t('seat_add_needs_payment_action', email: 'new-hire@example.com'))
      expect(AccountInvite.sole).to be_payment_pending
      expect(deliveries).to be_empty

      # Days later the customer finishes the card step in Stripe's own portal
      # and the subscription really does bill for two. That news arrives the
      # way every other Stripe fact does.
      Sidekiq::Queues.clear_all

      StripeBilling::SubscriptionSync.apply!(row, subscription_with_quantity(subscription_a, 2))

      invite_row = AccountInvite.sole.reload

      expect(row.reload.quantity).to eq(2)
      expect(invite_row).to be_pending
      expect(invite_row.payment_pending_until).to be_nil
      expect(invite_row.pending_quantity).to be_nil
      expect(invite_row.expires_at).to be_within(1.hour).of(BillingLifecycle::INVITE_TOKEN_DAYS.days.from_now)
      expect(deliveries.map(&:to).flatten).to include('new-hire@example.com')

      # And the seat is NOT handed back: somebody occupies it now.
      expect(Accounts.users_count(account)).to eq(2)
      expect(Sidekiq::Queues['billing'].select { |job| job['wrapped'] == 'ReconcileSeatsJob' }).to be_empty
    end

    # Checkpoint 7, P3. Two people invited while one card needed a second step
    # leave two parked rows, both bought at quantity 2 (the subscription still
    # billed 1 when each was priced). The customer finishes ONE of them and
    # Stripe bills for 2. Promoting both would mail two people an invitation
    # for one seat and put the account at 3 on a subscription that bills 2 —
    # and the second person would then be refused at the accept button, having
    # been told they were invited. Only the seat that was actually bought is
    # promoted; the other stays parked until Stripe's own deadline drops it.
    it 'promotes only as many parked purchases as the applied seats paid for' do
      row = stripe_paid!(account, seats: 1)
      stub_invoice_preview(amount_cents: 634)
      stub_subscription_update(subscription_a, quantity: 2,
                                               overrides: { 'pending_update' =>
                                                              { 'expires_at' => 20.hours.from_now.to_i } })

      invite('first-hire@example.com')
      post '/account_invites', params: { offer: offer_token }

      invite('second-hire@example.com')
      post '/account_invites', params: { offer: offer_token }

      first, second = AccountInvite.order(:id).to_a

      expect(AccountInvite.payment_pending.count).to eq(2)
      expect([first, second].map(&:pending_quantity)).to eq([2, 2])
      expect(deliveries).to be_empty

      # One card step finished. Stripe bills for two seats — one more than the
      # one the account already occupies, so exactly one invitation was paid
      # for.
      Sidekiq::Queues.clear_all

      StripeBilling::SubscriptionSync.apply!(row, subscription_with_quantity(subscription_a, 2))

      expect(row.reload.quantity).to eq(2)
      expect(first.reload).to be_pending
      expect(second.reload).to be_payment_pending
      expect(second).not_to be_pending

      # One person told they are invited, and it is the one who was waiting
      # longest.
      expect(deliveries.map(&:to).flatten).to eq(['first-hire@example.com'])

      # The rule underneath all of it: the account never occupies more seats
      # than the subscription bills for.
      expect(Accounts.seat_occupancy(account)).to eq(2)
      expect(Accounts.seat_occupancy(account)).to be <= row.quantity
    end

    # Checkpoint 7, V1. The cap above counts PROMOTIONS, not delivered mail.
    # The moment a parked row is flipped it is a live pending invitation
    # occupying its seat — so if the mail server hiccups on that one message,
    # the seat is still spent. Treating the failure as "nothing happened"
    # would promote the next parked row into the very same seat and put the
    # account back at two invitations for one paid-for seat, which is the
    # whole of P3. The failure is reported and the invitation is on the users
    # page with a Resend button; nobody else is promoted for it.
    it 'spends the seat on a promotion whose invitation email failed, and promotes nobody else' do
      row = stripe_paid!(account, seats: 1)
      stub_invoice_preview(amount_cents: 634)
      stub_subscription_update(subscription_a, quantity: 2,
                                               overrides: { 'pending_update' =>
                                                              { 'expires_at' => 20.hours.from_now.to_i } })

      invite('first-hire@example.com')
      post '/account_invites', params: { offer: offer_token }

      invite('second-hire@example.com')
      post '/account_invites', params: { offer: offer_token }

      first, second = AccountInvite.order(:id).to_a

      expect(AccountInvite.payment_pending.count).to eq(2)

      # The mail server is down for exactly the message the older row sends.
      allow(AccountInvites).to receive(:deliver!).and_wrap_original do |original, invite, *args|
        raise StandardError, 'smtp down' if invite.email == 'first-hire@example.com'

        original.call(invite, *args)
      end

      allow(ErrorReport).to receive(:error).and_call_original

      StripeBilling::SubscriptionSync.apply!(row, subscription_with_quantity(subscription_a, 2))

      # The seat the customer paid for was spent by the promotion, not by the
      # email: the older row is a live invitation and the younger one is still
      # parked.
      expect(row.reload.quantity).to eq(2)
      expect(first.reload).to be_pending
      expect(second.reload).to be_payment_pending
      expect(second).not_to be_pending

      # Nobody was mailed — the one message that was attempted failed — and
      # the failure was reported once rather than swallowed.
      expect(deliveries).to be_empty
      expect(ErrorReport).to have_received(:error).once

      # The rule underneath it: the account never occupies more seats than the
      # subscription bills for.
      expect(Accounts.seat_occupancy(account)).to eq(2)
      expect(Accounts.seat_occupancy(account)).to be <= row.quantity
    end

    # Checkpoint 7, V2. Stripe's own deadline for the card step has passed, so
    # the purchase can never be finished — the hourly sweep will settle the
    # row, but a seat applying in the meantime must not promote it.
    it 'never promotes a parked purchase whose payment deadline has passed' do
      row = stripe_paid!(account, seats: 1)
      parked = create(:account_invite, account:, email: 'lapsed@example.com',
                                       payment_pending_until: 30.minutes.ago,
                                       pending_quantity: 2, expires_at: 20.hours.from_now)

      StripeBilling::SubscriptionSync.apply!(row, subscription_with_quantity(subscription_a, 2))

      expect(parked.reload).not_to be_pending
      expect(parked.payment_pending_until).to be_present
      expect(deliveries).to be_empty
    end

    # The other half of the same rule: a row parked for a HIGHER quantity than
    # the one that applied was not paid for at all, so no amount of free seat
    # promotes it.
    it 'leaves a parked purchase alone when the applied quantity is below what it bought' do
      row = stripe_paid!(account, seats: 1)
      parked = create(:account_invite, account:, payment_pending_until: 20.hours.from_now,
                                       pending_quantity: 4, expires_at: 20.hours.from_now)

      StripeBilling::SubscriptionSync.apply!(row, subscription_with_quantity(subscription_a, 3))

      expect(parked.reload).to be_payment_pending
      expect(parked).not_to be_pending
      expect(deliveries).to be_empty
    end

    # Checkpoint 7, P6. A week is long enough for a parked address to close
    # its login somewhere else, and `assert_invitable!` answers that with
    # `AddressUnavailable`. That is an ordinary refusal like "they joined in
    # the meantime": the row is released, the seat goes back through the
    # normal reconciliation, and nobody is paged about it on every apply.
    it 'drops a parked purchase whose address has closed elsewhere, without paging anybody' do
      row = stripe_paid!(account, seats: 1)
      other = create(:account)
      create(:user, account: other, email: 'gone@example.com', archived_at: Time.current)

      parked = create(:account_invite, account:, email: 'gone@example.com',
                                       payment_pending_until: 20.hours.from_now,
                                       pending_quantity: 2, expires_at: 20.hours.from_now)

      allow(ErrorReport).to receive(:error).and_call_original

      Sidekiq::Queues.clear_all

      StripeBilling::SubscriptionSync.apply!(row, subscription_with_quantity(subscription_a, 2))

      expect(parked.reload.released_at).to be_present
      expect(parked).not_to be_payment_pending
      expect(parked).not_to be_pending
      expect(deliveries).to be_empty
      expect(ErrorReport).not_to have_received(:error)

      # The seat nobody can use is handed back the ordinary way.
      expect(Sidekiq::Queues['billing'].count { |job| job['wrapped'] == 'ReconcileSeatsJob' }).to eq(1)
    end

    it 'discards a parked purchase Stripe gave up on, and asks Stripe for nothing' do
      stripe_paid!(account, seats: 1)
      stub_invoice_preview(amount_cents: 634)
      stub_subscription_update(subscription_a, quantity: 2,
                                               overrides: { 'pending_update' =>
                                                              { 'expires_at' => 1.hour.from_now.to_i } })

      invite('new-hire@example.com')

      post '/account_invites', params: { offer: offer_token }

      parked = AccountInvite.sole

      expect(parked).to be_payment_pending

      # Stripe's own deadline for the card step passes and the subscription
      # was never changed, so there is nothing to hand back and nothing to
      # refund: the row is simply dropped.
      travel_to(2.hours.from_now) { BillingLifecycleJob.perform_now }

      expect(parked.reload.released_at).to be_present
      expect(parked).not_to be_payment_pending
      expect(parked).not_to be_pending
      expect(account.account_subscription.reload.quantity).to eq(1)
      expect(deliveries).to be_empty

      # One POST to Stripe in the whole example: the purchase it parked.
      expect(WebMock).to(
        have_requested(:post, "https://api.stripe.com/v1/subscriptions/#{subscription_a}").once
      )
    end

    it 'still takes back a seat that arrived with no parked purchase behind it' do
      row = stripe_paid!(account, seats: 1)

      # A quantity the app never asked for — a hand-back that failed while
      # Stripe was unreachable, or an edit in Stripe's own dashboard. Nobody
      # was ever invited into it, so applying that news asks for it back —
      # from a JOB, once the webhook's own transaction is over, and never with
      # an outbound call from inside the lock that is applying it.
      Sidekiq::Queues.clear_all

      StripeBilling::SubscriptionSync.apply!(row, subscription_with_quantity(subscription_a, 2))

      expect(row.reload.quantity).to eq(2)

      queued = Sidekiq::Queues['billing'].select { |job| job['wrapped'] == 'ReconcileSeatsJob' }

      expect(queued.size).to eq(1)
      expect(queued.first.dig('args', 0, 'arguments')).to eq([row.id])

      stub_subscription_update(subscription_a, quantity: 1)
      stub_subscription_reread(subscription_a, quantity: 1)

      # The job as it was actually queued, run the way Sidekiq would run it.
      Sidekiq::Worker.drain_all

      expect(row.reload.quantity).to eq(1)
    end

    it 'brings a subscription that quietly bills for too many seats back down on the hourly sweep' do
      row = stripe_paid!(account, seats: 1)
      # Drift the app never saw happen: the row simply says two, and one
      # person occupies the account.
      row.update_columns(quantity: 2)
      stub_subscription_update(subscription_a, quantity: 1)
      stub_subscription_reread(subscription_a, quantity: 1)

      BillingLifecycle.reconcile_seats!

      expect(row.reload.quantity).to eq(1)

      # And it asks for nothing once the two numbers agree.
      BillingLifecycle.reconcile_seats!

      expect(WebMock).to(
        have_requested(:post, "https://api.stripe.com/v1/subscriptions/#{subscription_a}").once
      )
    end

    it 'leaves a lapsed invitation unsettled when Stripe refuses, and settles it on the next tick' do
      row = stripe_paid!(account, seats: 2)
      lapsed = create(:account_invite, account:, expires_at: 1.hour.ago)

      stub_request(:post, "https://api.stripe.com/v1/subscriptions/#{subscription_a}")
        .to_return(status: 500, body: { error: { message: 'Stripe is having a moment' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      BillingLifecycle.expire_invites!

      # Nothing was handed back, so nothing is marked handled: the seat is
      # still ours to reclaim.
      expect(lapsed.reload.released_at).to be_nil
      expect(row.reload.quantity).to eq(2)

      stub_subscription_update(subscription_a, quantity: 1)
      stub_subscription_reread(subscription_a, quantity: 1)

      BillingLifecycle.expire_invites!

      expect(lapsed.reload.released_at).to be_present
      expect(row.reload.quantity).to eq(1)
    end

    it 'sweeps a cancelled invitation whose hand-back failed at the time' do
      row = stripe_paid!(account, seats: 2)
      invite_row = create(:account_invite, account:)

      stub_request(:post, "https://api.stripe.com/v1/subscriptions/#{subscription_a}")
        .to_return(status: 500, body: { error: { message: 'Stripe is having a moment' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      delete "/account_invites/#{invite_row.id}"

      expect(invite_row.reload.revoked_at).to be_present
      expect(invite_row.released_at).to be_nil

      stub_subscription_update(subscription_a, quantity: 1)
      stub_subscription_reread(subscription_a, quantity: 1)

      BillingLifecycle.expire_invites!

      expect(invite_row.reload.released_at).to be_present
      expect(row.reload.quantity).to eq(1)
    end
  end

  describe 'accepting an invitation' do
    let(:invite_row) { create(:account_invite, account:, role: User::EDITOR_ROLE) }
    let(:token) { invite_row.raw_token }

    before do
      stripe_paid!(account, seats: 2)
      invite_row
      anonymous!
    end

    it 'creates the person with the role the invitation carried, and does not move occupancy' do
      get "/invites/#{token}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ERB::Util.html_escape(account.name))

      expect do
        post "/invites/#{token}", params: { first_name: 'Sam', last_name: 'Rivers', password: 'password-123' }
      end.to change(User, :count).by(1)

      created = User.find_by!(email: invite_row.email)

      expect(created.account).to eq(account)
      expect(created.role).to eq(User::EDITOR_ROLE)
      expect(created).to be_confirmed
      expect(created.full_name).to eq('Sam Rivers')
      expect(invite_row.reload.accepted_at).to be_present
      # The pending invite's seat became their seat.
      expect(Accounts.users_count(account)).to eq(2)

      # They are signed in and working.
      get '/templates'

      expect(response).to have_http_status(:ok)
    end

    it 'refuses an expired, cancelled or already used link with a page that says so' do
      invite_row.update!(expires_at: 1.hour.ago)

      get "/invites/#{token}"

      expect(response).to have_http_status(:gone)
      expect(response.body).to include(I18n.t('invite_unavailable_title'))

      expect do
        post "/invites/#{token}", params: { first_name: 'Sam', last_name: 'Rivers', password: 'password-123' }
      end.not_to change(User, :count)

      expect(response).to have_http_status(:gone)
    end

    it 'refuses a token nobody minted' do
      get '/invites/not-a-real-token'

      expect(response).to have_http_status(:gone)
    end
  end

  # Review batch 1, F4: everything that can change between the acceptance page
  # being rendered and the button being pressed.
  describe 'an invitation whose world moved on' do
    let(:invite_row) { create(:account_invite, account:, role: User::EDITOR_ROLE) }
    let(:token) { invite_row.raw_token }

    before do
      stripe_paid!(account, seats: 3)
      invite_row
      anonymous!
    end

    def accept!
      post "/invites/#{token}", params: { first_name: 'Sam', last_name: 'Rivers', password: 'password-123' }
    end

    it 'refuses to add anybody to a team that is frozen for a failed payment' do
      AccountStates.suspend!(account, reason: 'billing')

      get "/invites/#{token}"

      expect(response).to have_http_status(:gone)
      expect(response.body).to include(I18n.t('invite_account_frozen'))

      expect { accept! }.not_to change(User, :count)

      expect(response).to have_http_status(:gone)
      expect(invite_row.reload.accepted_at).to be_nil
    end

    # The acceptance is holding an invitation object it loaded BEFORE the
    # cancel happened — which is exactly the race: `pending?` on that object
    # still says yes. Only re-reading it under the row lock can see the
    # cancel, so this fails the moment with_open_invite stops doing that.
    it 'refuses an invitation cancelled underneath it, on the object it is holding' do
      stub_subscription_update(subscription_a, quantity: 1)
      stub_subscription_reread(subscription_a, quantity: 1)

      stale = AccountInvite.find(invite_row.id)

      expect(stale).to be_pending

      AccountInvites.revoke!(AccountInvite.find(invite_row.id))

      expect(stale).to be_pending

      expect do
        expect do
          AccountInvites.accept!(stale, first_name: 'Sam', last_name: 'Rivers', password: 'password-123')
        end.to raise_error(AccountInvites::NoLongerOpen)
      end.not_to change(User, :count)

      # And through the door, the same answer with a page on it.
      expect { accept! }.not_to change(User, :count)

      expect(response).to have_http_status(:gone)
    end

    # The plan shrank while the invitation was in the post: accepting would
    # otherwise hand a one-seat account a second full-access member.
    it 'refuses when the seat it was holding is no longer there' do
      account.account_subscription.update!(access_state: 'cancelled', status: 'canceled',
                                           stripe_status: 'canceled')

      expect(Plans.key_for(account.reload)).to eq(Plans::FREE)

      expect { accept! }.not_to change(User, :count)

      expect(response).to have_http_status(:gone)
      expect(response.body).to include(I18n.t('invite_no_seat_left'))
      expect(invite_row.reload.accepted_at).to be_nil
    end
  end

  describe 'an address that already has an account of its own' do
    let(:other_account) { create(:account) }
    let!(:other_user) { create(:user, account: other_account) }

    before { stripe_paid!(account, seats: 2) }

    # D50: the old behaviour was "email has already been taken", which leaves
    # the invitee stuck with nothing to click.
    it 'is an offer to join, never a validation error' do
      expect { invite(other_user.email) }.to change(AccountInvite, :count).by(1)

      expect(response).to redirect_to('/settings/users')
      expect(response.body).not_to include(I18n.t('already_exists'))
      expect(response.body).not_to include('already been taken')

      invite_row = AccountInvite.sole

      # `collision?` was renamed `collision_hinted?` in review-7's B1/B2 fix:
      # the column is a hint for the invitation email's copy and authorizes
      # nothing. What the link DOES is asked from the address on every
      # request (AccountInvites.verdict_for), and is asserted as such below.
      expect(invite_row).to be_collision_hinted
      expect(invite_row.collision_user).to eq(other_user)
      expect(AccountInvites.verdict_for(invite_row)).to eq(:move)
    end

    it 'says in the email what accepting will do', sidekiq: :inline do
      invite(other_user.email)

      mail = deliveries.sole

      # Escaped, because the body is HTML and a company name with an
      # apostrophe in it comes out as `&#39;` — matching the raw name passes
      # or fails on what Faker happened to generate.
      expect(body_of(mail)).to include(ERB::Util.html_escape(other_account.name))
      expect(body_of(mail)).to include(ERB::Util.html_escape(account.name))
    end

    # D4: the accept link is a BEARER CREDENTIAL. Whoever holds that token can
    # create a confirmed user in this account with a password of their own
    # choosing (AccountInvites.accept!), which is why the row itself only ever
    # stores its digest — nothing that comes back out of the database can
    # rebuild the link.
    #
    # `deliver_later!` was quietly undoing that. It wrote the raw token, in
    # plain text, into a Sidekiq job's arguments, where it sits in Redis while
    # the job waits, again on every retry, and indefinitely in the dead set if
    # delivery keeps failing — and where it is printed in full on the Sidekiq
    # Web UI this app mounts in production. The mail is delivered inline
    # instead, so the token lives in one process's memory for the length of one
    # request and is written nowhere.
    #
    # Deliberately NOT tagged `sidekiq: :inline`: with the queue in fake mode,
    # a mail that arrives in `deliveries` at all is a mail that was never
    # enqueued.
    it 'sends the invitation without ever putting its token in a job payload' do
      invite(other_user.email)

      token = token_from_mail

      expect(token).to be_present
      expect(deliveries.size).to eq(1)
      expect(AccountInvite.sole.raw_token).to be_nil

      queued = Sidekiq::Queues.jobs_by_queue.values.flatten.to_json

      expect(queued).not_to include(token)
      # And the link really is live, which is what makes the secrecy matter.
      anonymous!
      get "/invites/#{token}"

      expect(response).to redirect_to(new_user_session_path)
    end

    it 'asks the invitee to sign in as themselves before it will say anything else', sidekiq: :inline do
      invite(other_user.email)
      anonymous!

      get "/invites/#{token_from_mail}"

      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to include(other_user.email)
    end
  end

  describe 'joining a team with everything you own' do
    let(:other_account) { create(:account) }
    let!(:other_user) { create(:user, account: other_account) }
    let(:invite_row) do
      create(:account_invite, account:, email: other_user.email, role: User::EDITOR_ROLE,
                              collision_user: other_user)
    end

    before do
      stripe_paid!(account, seats: 3)
      platform_certificate!
    end

    it 'moves the person, their folders, templates and documents, and archives the account they left',
       sidekiq: :inline do
      template = create(:template, account: other_account, author: other_user, only_field_types: %w[text])
      submission = Submissions.create_from_emails(template:, user: other_user, emails: unique_email,
                                                  source: :invite, mark_as_sent: true).sole
      anonymous!
      complete!(submission.submitters.sole)

      completed = CompletedSubmitter.where(account_id: other_account.id)
      verified = VerifiedDocument.where(account_id: other_account.id)

      expect(completed).to be_present
      expect(verified).to be_present

      completed_ids = completed.ids
      verified_ids = verified.ids
      token = invite_row.raw_token

      act_as(other_user)

      expect { post "/invites/#{token}" }.to change(AccountMove, :count).by(1)

      expect(response).to redirect_to(root_path)
      expect(other_user.reload.account).to eq(account)
      expect(other_user.role).to eq(User::EDITOR_ROLE)
      expect(template.reload.account).to eq(account)
      expect(submission.reload.account).to eq(account)
      expect(submission.submitters.sole.reload.account_id).to eq(account.id)
      expect(other_account.reload.archived_at).to be_present
      expect(invite_row.reload.accepted_at).to be_present

      # Folders merge by name: the account they left had a Default folder and
      # so does the team, and there is still exactly one afterwards.
      expect(account.template_folders.where(name: TemplateFolder::DEFAULT_NAME).count).to eq(1)
      expect(template.reload.folder.account_id).to eq(account.id)
      expect(TemplateFolder.where(account_id: other_account.id)).to be_empty

      # History does not move house: metering is prospective (D43) and the
      # public /verify record says who signed it at the time.
      expect(CompletedSubmitter.where(id: completed_ids).pluck(:account_id).uniq).to eq([other_account.id])
      expect(VerifiedDocument.where(id: verified_ids).pluck(:account_id).uniq).to eq([other_account.id])

      move = AccountMove.sole

      expect(move.from_account).to eq(other_account)
      expect(move.to_account).to eq(account)
      expect(move.user).to eq(other_user)
    end

    # The Doorkeeper pair upstream DocuSeal left in the schema has no model in
    # this app; the rows go in the way the purge takes them out, through a
    # relation on the bare table.
    def oauth_applications
      Class.new(ApplicationRecord) { self.table_name = 'oauth_applications' }
    end

    # A move is a security-boundary transition, and every key cut for the old
    # account is thrown away as part of it.
    #
    # API and MCP auth resolve the TENANT through the person: the token names
    # its user and `current_account` is `user.account`. So a token minted while
    # this person was alone in their own one-person account would, the instant
    # the move landed, start answering for the TEAM — at the role the
    # invitation granted, over documents the team's administrators own, on a
    # credential none of them issued, can see or could revoke. The free account
    # it was cut for has no API at all, which is the measure of the escalation:
    # 403 before, and it must not become 200 after.
    it 'throws away every credential the account being left had issued' do
      api_token = other_user.access_token.token
      mcp_token = other_user.mcp_tokens.create!(name: 'Old laptop').token
      application = oauth_applications.create!(name: 'Partner', uid: SecureRandom.hex, scopes: 'read',
                                               secret: SecureRandom.hex, redirect_uri: 'https://example.com/cb')
      Accounts::Purge::OauthAccessGrant.create!(application_id: application.id, resource_owner_id: other_user.id,
                                                token: SecureRandom.hex, expires_in: 600,
                                                redirect_uri: 'https://example.com/cb', scopes: 'read')
      Accounts::Purge::OauthAccessToken.create!(application_id: application.id, resource_owner_id: other_user.id,
                                                token: SecureRandom.hex, scopes: 'read',
                                                previous_refresh_token: 'none')

      other_user.remember_me!
      remember_token = other_user.rememberable_value
      # Devise refuses a cookie stamped before `remember_created_at`, so the
      # cookie is dated the way the real one is: after the row was written.
      remembered_at = 1.second.from_now

      expect(User.serialize_from_cookie(other_user.id, remember_token, remembered_at)).to eq(other_user)

      token = invite_row.raw_token
      act_as(other_user)

      # The free personal account has no API, so the token is refused for the
      # ordinary reason before the move — it exists and it resolves.
      get '/api/templates', headers: { 'x-auth-token': api_token }

      expect(response).to have_http_status(:forbidden)

      post "/invites/#{token}"

      expect(response).to redirect_to(root_path)
      expect(other_user.reload.account).to eq(account)

      # The browser that pressed the button is the one credential that should
      # survive: they are still signed in, and they are in the team.
      get '/templates'

      expect(response).to have_http_status(:ok)

      expect(AccessToken.where(user_id: other_user.id)).to be_empty
      expect(McpToken.where(user_id: other_user.id)).to be_empty
      expect(McpToken.where(sha256: Digest::SHA256.hexdigest(mcp_token))).to be_empty
      expect(Accounts::Purge::OauthAccessGrant.where(resource_owner_id: other_user.id)).to be_empty
      expect(Accounts::Purge::OauthAccessToken.where(resource_owner_id: other_user.id)).to be_empty
      expect(other_user.remember_created_at).to be_nil

      # Devise judges a remember-me cookie against `remember_created_at`, and
      # with the column cleared it refuses every cookie stamped before now.
      # Read from a moment after the cookie was stamped, so the assertion does
      # not depend on how long this example happened to take.
      travel_to(remembered_at + 1.second) do
        expect(User.serialize_from_cookie(other_user.id, remember_token, remembered_at)).to be_nil
      end

      # And the old API token does not inherit the team it was never issued
      # for: not the team's paid API, not anything.
      anonymous!

      get '/api/templates', headers: { 'x-auth-token': api_token }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq('error' => 'Not authenticated')
    end

    it 'refuses, with an explanation, when the account being left has other people in it' do
      create(:user, account: other_account)
      token = invite_row.raw_token
      act_as(other_user)

      expect { post "/invites/#{token}" }.not_to change(AccountMove, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('invite_move_other_members'))
      expect(other_user.reload.account).to eq(other_account)
    end

    # Review batch 1, F6: `Plans.paid_subscription?` says no for a subscription
    # Stripe has given up on, one that is paused, and one that never completed
    # its first payment — and every one of those is still a live subscription
    # that can charge a card. Archiving the account underneath it would leave
    # money moving with nothing on our side watching it.
    %w[unpaid paused incomplete].each do |status|
      it "refuses while the account being left still has a #{status} subscription at Stripe" do
        create(:account_subscription, account: other_account, access_state: 'cancelled', status:,
                                      stripe_status: status, stripe_customer_id: customer_b,
                                      stripe_subscription_id: subscription_b)
        token = invite_row.raw_token
        act_as(other_user)

        expect { post "/invites/#{token}" }.not_to change(AccountMove, :count)

        expect(response.body).to include(I18n.t('invite_move_paid_subscription'))
        expect(other_user.reload.account).to eq(other_account)
        expect(other_account.reload.archived_at).to be_nil
      end
    end

    # F10: document_metadata is one row per (account, file checksum) — a
    # unique index — and two accounts that have signed the same file each hold
    # their own. Re-parenting the incoming one used to take the whole move
    # down with a duplicate-key error.
    it 'moves an account that has signed the same file the team has' do
      checksum = Digest::SHA256.hexdigest('the same bytes')
      DocumentMetadata.create!(account:, blob_checksum: checksum, text_runs: 'theirs')
      DocumentMetadata.create!(account: other_account, blob_checksum: checksum, text_runs: 'mine')
      DocumentMetadata.create!(account: other_account, blob_checksum: 'only-mine', text_runs: 'mine alone')
      token = invite_row.raw_token
      act_as(other_user)

      expect { post "/invites/#{token}" }.to change(AccountMove, :count).by(1)

      expect(other_user.reload.account).to eq(account)
      # One row for the shared file — the one that was already there — and the
      # file only they had came across.
      expect(DocumentMetadata.where(blob_checksum: checksum).pluck(:account_id, :text_runs))
        .to eq([[account.id, 'theirs']])
      expect(DocumentMetadata.find_by(blob_checksum: 'only-mine').account_id).to eq(account.id)
    end

    it 'refuses, with an explanation, when the account being left is still paying' do
      create(:account_subscription, account: other_account, access_state: 'active', status: 'active', quantity: 1)
      token = invite_row.raw_token
      act_as(other_user)

      expect { post "/invites/#{token}" }.not_to change(AccountMove, :count)

      expect(response.body).to include(I18n.t('invite_move_paid_subscription'))
      expect(other_user.reload.account).to eq(other_account)
    end

    it 'refuses to move an internal account' do
      other_account.update!(account_kind: Account::INTERNAL_KIND)
      token = invite_row.raw_token
      act_as(other_user)

      expect { post "/invites/#{token}" }.not_to change(AccountMove, :count)

      expect(response.body).to include(I18n.t('invite_move_not_a_personal_account'))
    end

    it 'refuses to act on somebody else\'s invitation' do
      stranger = create(:user)
      token = invite_row.raw_token
      act_as(stranger)

      expect { post "/invites/#{token}" }.not_to change(AccountMove, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(other_user.email)
    end

    # D1: a live browser session must not follow the person across the tenant
    # boundary.
    #
    # The previous round threw away every credential the old account had cut —
    # API tokens, MCP tokens, OAuth grants, remember-me — and could not touch
    # the one that matters most: a signed-in browser. This app resolves the
    # tenant dynamically (`current_account` is `current_user.account`, read
    # fresh on every request), so a session cookie minted while this person was
    # alone in their own free account went on working after the move and simply
    # started answering for the TEAM, at whatever role the invitation granted.
    # A laptop left signed in at home, a shared machine, a session somebody
    # else is holding: none of them are things the team's administrators can
    # see, and every one of them became a door into the team's documents.
    #
    # `users.session_version` is what closes it: it is appended to the salt
    # Devise stamps into every session and remember-me cookie
    # (User#authenticatable_salt) and re-compared out of the database on every
    # request, so bumping it inside the move's transaction refuses every cookie
    # minted before it. The browser that pressed the button is re-established
    # explicitly and is the only one that survives.
    it 'signs the person out of every other browser, and keeps only the one that pressed the button' do
      token = invite_row.raw_token

      # A second browser with its own cookie jar, signed in and working before
      # the move — the pattern spec/golden/quota_spec.rb uses for two live
      # sessions of one person.
      elsewhere = open_session
      sign_in(other_user)
      elsewhere.get '/templates'

      expect(elsewhere.response).to have_http_status(:ok)

      # And a remember-me cookie from the same era, which is the half of a
      # session that survives the browser being closed.
      other_user.remember_me!
      remember_token = other_user.rememberable_value
      remembered_at = 1.second.from_now

      expect(User.serialize_from_cookie(other_user.id, remember_token, remembered_at)).to eq(other_user)

      act_as(other_user)

      expect { post "/invites/#{token}" }.to change { other_user.reload.session_version }.by(1)

      expect(response).to redirect_to(root_path)
      expect(other_user.account).to eq(account)

      # The browser that asked for the move is still signed in, and it is in
      # the team it just joined.
      get '/templates'

      expect(response).to have_http_status(:ok)

      # The one that was left signed in somewhere else is not, and it never
      # sees a single page of the team's data.
      elsewhere.get '/templates'

      # Asserted on the other session's own response object rather than with
      # `redirect_to`, which reads the response of the example's MAIN session
      # and would quietly pass on the request one line up.
      expect(elsewhere.response).to have_http_status(:found)
      expect(elsewhere.response.location).to end_with(new_user_session_path)
      expect(elsewhere.session['warden.user.user.key']).to be_nil

      # Read from a moment after the cookie was stamped, so the assertion does
      # not depend on how long this example happened to take.
      travel_to(remembered_at + 1.second) do
        expect(User.serialize_from_cookie(other_user.id, remember_token, remembered_at)).to be_nil
      end
    end

    # D2: two teams, one person, two invitations accepted at the same moment.
    #
    # Everything about a move used to be decided BEFORE its transaction opened
    # — `user.account` and every eligibility check — and the acceptance door
    # locked only the invitation row. Two invitations are two different rows
    # and therefore two different locks, so both passes could agree that this
    # person was alone in their own account: the first moved the documents into
    # B, the second found nothing left to move (`where(account_id: A)` matched
    # no rows by then) and moved only the PERSON, into C. They ended in C with
    # every document they own sitting inside B — a tenant they are not a member
    # of — and both AccountMove rows recorded a success.
    #
    # The interleaving is reproduced without threads, and exactly: the second
    # acceptance is handed the user object as it was BEFORE the first one ran,
    # which is precisely what a request that read the row a moment earlier is
    # holding. What the fix does is refuse it — the account this acceptance was
    # authorized over is not the account the locked row is in any more.
    it 'lets exactly one of two invitations move the person, and never splits them from their documents' do
      second_team = create(:account)

      create(:user, account: second_team)
      stripe_paid!(second_team, seats: 3, subscription_id: subscription_b, customer_id: customer_b)

      template = create(:template, account: other_account, author: other_user, only_field_types: %w[text])
      to_second = create(:account_invite, account: second_team, email: other_user.email,
                                          role: User::EDITOR_ROLE, collision_user: other_user)

      # The user as the second request read it: still alone in their own
      # account, because at the moment it loaded the row they were.
      in_flight = User.find(other_user.id)

      expect(in_flight.account_id).to eq(other_account.id)

      AccountInvites.accept_move!(invite_row, user: other_user)

      expect { AccountInvites.accept_move!(to_second, user: in_flight) }
        .to raise_error(Accounts::MoveUser::Refused, I18n.t('invite_move_already_moved'))

      # One move, one team, and the documents are in it with them.
      expect(AccountMove.count).to eq(1)
      expect(other_user.reload.account).to eq(account)
      expect(template.reload.account).to eq(account)
      expect(Template.where(account_id: second_team.id)).to be_empty
      expect(invite_row.reload.accepted_at).to be_present
      expect(to_second.reload).to be_pending
    end

    # D5: the lifecycle of the account being LEFT.
    #
    # A move is the largest write this app makes on an account — every
    # template, every document and every folder changes tenant, and the account
    # is closed behind them — and it used to ask nothing at all about whether
    # that account was allowed to be written. Two of these are the reason it
    # matters: an account whose purge has been CLAIMED is being emptied right
    # now in another process, and an account with a deletion pending is under a
    # promise to destroy exactly this data. Moving out of either leaves
    # documents that were meant to be deleted alive inside somebody else's
    # tenant.
    #
    # The purge-claimed and archived cases are asked of the module rather than
    # through the browser on purpose: Devise refuses to hold a session for
    # somebody whose account is in either state (User#active_for_authentication?),
    # so the only way they are reached in life is a claim landing after a
    # request has already been authorized — which is exactly this call.
    it 'refuses to move out of an account a purge has already claimed' do
      other_account.update!(purge_started_at: Time.current)

      expect { AccountInvites.accept_move!(invite_row, user: other_user) }
        .to raise_error(Accounts::MoveUser::Refused, I18n.t('invite_move_source_purging'))

      expect(other_user.reload.account).to eq(other_account)
      expect(invite_row.reload).to be_pending
    end

    it 'refuses to move out of an account that is already archived' do
      other_account.update!(archived_at: Time.current)

      expect { AccountInvites.accept_move!(invite_row, user: other_user) }
        .to raise_error(Accounts::MoveUser::Refused, I18n.t('invite_move_source_archived'))

      expect(other_user.reload.account).to eq(other_account)
      expect(invite_row.reload).to be_pending
    end

    it 'refuses, with an explanation, when the account being left is scheduled for deletion' do
      other_account.update!(deletion_requested_at: Time.current,
                            purge_scheduled_for: Accounts::Deletion::WINDOW_DAYS.days.from_now)
      token = invite_row.raw_token
      act_as(other_user)

      expect { post "/invites/#{token}" }.not_to change(AccountMove, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('invite_move_source_pending_deletion'))
      expect(other_user.reload.account).to eq(other_account)
      expect(other_account.reload.archived_at).to be_nil
    end

    it 'refuses, with an explanation, when the account being left is frozen' do
      AccountStates.suspend!(other_account, reason: AccountStates::BILLING_REASON)
      token = invite_row.raw_token
      act_as(other_user)

      expect { post "/invites/#{token}" }.not_to change(AccountMove, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('invite_move_source_frozen'))
      expect(other_user.reload.account).to eq(other_account)
      expect(other_account.reload.archived_at).to be_nil
    end
  end

  # Review 7 (B1/B2/B3, D3): who an invitation is FOR is asked from the invited
  # ADDRESS on every request, never from the collision_user_id the row was
  # written with. Every ordering below is one the old code could not survive,
  # because it decided "is this a collision?" once — when the invitation was
  # written — and never asked again.
  describe 'who the invitation is for, asked again at accept time' do
    let(:invited_email) { unique_email }

    before do
      stripe_paid!(account, seats: 3)
      platform_certificate!
    end

    # D50, in one line: whatever else happens, the invitee never meets the
    # unique email index's own words.
    def no_validation_error!
      expect(response.body).not_to include('already been taken')
      expect(response.body).not_to include(I18n.t('already_exists'))
    end

    # B1, and the commonest ordering there is: the admin invites somebody who
    # has no account yet, and they sign themselves up before they get round to
    # the link. This used to render the sign-up form and answer the button
    # with "Email has already been taken" — a dead end, with the seat still
    # held for the rest of the week.
    it 'offers the move when the invitee signed themselves up after the invitation was sent',
       sidekiq: :inline do
      invite(invited_email, role: User::EDITOR_ROLE)
      token = token_from_mail
      invite_row = AccountInvite.sole

      # Nothing was a collision when this was written.
      expect(invite_row.collision_user_id).to be_nil
      expect(invite_row).not_to be_collision_hinted

      # They gave up waiting and made an account of their own.
      own_account = create(:account)
      late = create(:user, account: own_account, email: invited_email)
      template = create(:template, account: own_account, author: late, only_field_types: %w[text])
      occupancy = Accounts.seat_occupancy(account)

      expect(AccountInvites.verdict_for(invite_row)).to eq(:move)

      anonymous!
      get "/invites/#{token}"

      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to include(invited_email)

      act_as(late)
      get "/invites/#{token}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ERB::Util.html_escape(I18n.t('invite_move_heading', team: account.name)))
      no_validation_error!

      expect { post "/invites/#{token}" }.to change(AccountMove, :count).by(1)

      expect(response).to redirect_to(root_path)
      expect(late.reload.account).to eq(account)
      expect(late.role).to eq(User::EDITOR_ROLE)
      expect(template.reload.account).to eq(account)
      expect(own_account.reload.archived_at).to be_present
      expect(invite_row.reload.accepted_at).to be_present
      # The invitation's seat became their seat: occupancy has not moved.
      expect(Accounts.seat_occupancy(account)).to eq(occupancy)
    end

    # The money version of the same ordering. The seat was BOUGHT for that
    # address, so the person who arrives at it must consume THAT seat — not
    # leave it paid for and unusable while a second one is bought for them.
    it 'consumes the very seat that was bought for the address', sidekiq: :inline do
      row = account.account_subscription
      row.update!(quantity: 1)
      stub_invoice_preview(amount_cents: 634)
      invite(invited_email)

      stub_subscription_update(subscription_a, quantity: 2)
      stub_subscription_reread(subscription_a, quantity: 2)

      expect { post '/account_invites', params: { offer: offer_token } }.to change(AccountInvite, :count).by(1)

      expect(row.reload.quantity).to eq(2)

      token = token_from_mail
      own_account = create(:account)
      late = create(:user, account: own_account, email: invited_email)

      act_as(late)

      expect { post "/invites/#{token}" }.to change(AccountMove, :count).by(1)

      expect(late.reload.account).to eq(account)
      # Two seats billed, two seats occupied: nothing was handed back and
      # nothing was bought a second time.
      expect(row.reload.quantity).to eq(2)
      expect(Accounts.seat_occupancy(account)).to eq(2)
    end

    # B2: the person the invitation named changes their own address afterwards,
    # and somebody else takes the invited one. Keyed on the stored user id,
    # the button moved a DIFFERENT address — and every document in its
    # account — into a team that had never invited it.
    it 'refuses the person whose address is no longer the invited one' do
      own_account = create(:account)
      mover = create(:user, account: own_account, email: invited_email)
      invite_row = create(:account_invite, account:, email: invited_email, role: User::EDITOR_ROLE,
                                           collision_user: mover)
      token = invite_row.raw_token

      mover.update!(email: unique_email)
      holder_account = create(:account)
      holder = create(:user, account: holder_account, email: invited_email)

      act_as(mover)
      get "/invites/#{token}"

      expect(response).to have_http_status(:ok)
      # The invitation names the ADDRESS, and the address is what the page
      # asks them to sign in as.
      expect(response.body).to include(
        ERB::Util.html_escape(I18n.t('invite_sign_in_as_other_user', email: invited_email))
      )
      expect(response.body).not_to include(ERB::Util.html_escape(I18n.t('invite_move_button', team: account.name)))
      no_validation_error!

      expect { post "/invites/#{token}" }.not_to change(AccountMove, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(
        ERB::Util.html_escape(I18n.t('invite_sign_in_as_other_user', email: invited_email))
      )
      expect(mover.reload.account).to eq(own_account)
      expect(holder.reload.account).to eq(holder_account)
      expect(invite_row.reload).to be_pending

      # And the lock says the same thing, on an object that never went near
      # the controller: the equality is re-asserted where the move happens.
      expect { AccountInvites.accept_move!(invite_row, user: mover) }
        .to raise_error(AccountInvites::WrongInvitee, /#{Regexp.escape(invited_email)}/)
    end

    # B3: an archived login in another account holds the address. Nobody can
    # ever sign in as it, so the invitation is a seat held — and, on a paid
    # account with no free seat, a seat BOUGHT — for a link that can never be
    # used. No Stripe call is made at all: the refusal comes before the price.
    it 'refuses an address that belongs to a closed login, before anything is priced or charged' do
      account.account_subscription.update!(quantity: 1)
      ghost = create(:user, account: create(:account), email: invited_email, archived_at: Time.current)

      expect { invite(ghost.email) }.not_to change(AccountInvite, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('invite_address_closed_admin'))
      expect(WebMock).not_to have_requested(:any, %r{\Ahttps://api\.stripe\.com})
      no_validation_error!
    end

    it 'says so on a link written for a closed login before that rule existed' do
      ghost = create(:user, account: create(:account), email: invited_email, archived_at: Time.current)
      invite_row = create(:account_invite, account:, email: invited_email, collision_user: ghost)
      token = invite_row.raw_token

      anonymous!
      get "/invites/#{token}"

      expect(response).to have_http_status(:gone)
      expect(response.body).to include(I18n.t('invite_address_closed_login'))
      no_validation_error!

      expect do
        post "/invites/#{token}", params: { first_name: 'Sam', last_name: 'Rivers', password: 'password-123' }
      end.not_to change(User, :count)

      expect(response).to have_http_status(:gone)
      expect(response.body).to include(I18n.t('invite_address_closed_login'))
      no_validation_error!
    end

    # Q-3: the user row is untouched, but the ACCOUNT they are in has been
    # archived (or its purge claimed), and nobody in such an account can sign
    # in at all. So the move this invitation offers could never be accepted,
    # and the seat it holds was bought for a link that can never be used. It
    # is answered with the closed-login sentence rather than a join screen
    # nobody can get past.
    it 'treats an invitee whose own account has closed as a closed login' do
      shuttered = create(:account, archived_at: Time.current)
      stranded = create(:user, account: shuttered, email: invited_email)
      invite_row = create(:account_invite, account:, email: invited_email, collision_user: stranded)

      expect(stranded.archived_at).to be_nil
      expect(AccountInvites.verdict_for(invite_row)).to eq(:closed_login)

      anonymous!
      get "/invites/#{invite_row.raw_token}"

      expect(response).to have_http_status(:gone)
      expect(response.body).to include(I18n.t('invite_address_closed_login'))
      no_validation_error!

      # And the same answer for an account whose purge has been claimed, whose
      # rows are still there and whose people still cannot sign in.
      claimed = create(:account, purge_started_at: Time.current)
      other_invite = create(:account_invite, account:, email: unique_email)
      create(:user, account: claimed, email: other_invite.email)

      expect(AccountInvites.verdict_for(other_invite)).to eq(:closed_login)
    end

    # The address is already in the team — they accepted another copy of the
    # link, or an admin created them by hand. There is nothing to accept, and
    # the seat the invitation is still holding goes back.
    it 'hands the seat back when the invited address is already a member' do
      row = account.account_subscription
      create(:user, account:, email: invited_email)
      invite_row = create(:account_invite, account:, email: invited_email)
      stub_subscription_update(subscription_a, quantity: 2)
      stub_subscription_reread(subscription_a, quantity: 2)

      anonymous!
      get "/invites/#{invite_row.raw_token}"

      expect(response).to have_http_status(:gone)
      expect(response.body).to include(ERB::Util.html_escape(I18n.t('invite_already_member', team: account.name)))
      expect(invite_row.reload.revoked_at).to be_present
      expect(invite_row.released_at).to be_present
      expect(row.reload.quantity).to eq(2)
      no_validation_error!
    end

    # D3: D50 says the move is "stated in the flow". It is stated in two
    # places — the invitation email and the join screen — and until now
    # neither was pinned by any example, so either could have been deleted in
    # silence.
    it 'states on the screen and in the mail that the documents move', sidekiq: :inline do
      own_account = create(:account)
      joiner = create(:user, account: own_account, email: invited_email)

      invite(invited_email)
      token = token_from_mail
      mail_body = body_of(deliveries.last)

      expect(mail_body).to include('templates, documents and folders')
      expect(mail_body).to include(ERB::Util.html_escape(own_account.name))
      expect(mail_body).to include(ERB::Util.html_escape(account.name))
      expect(mail_body).to include(invited_email)

      act_as(joiner)
      get "/invites/#{token}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(
        ERB::Util.html_escape(I18n.t('invite_move_point_documents', old_team: own_account.name, team: account.name))
      )
      expect(response.body).to include(
        ERB::Util.html_escape(I18n.t('invite_move_point_closed', old_team: own_account.name))
      )
      expect(response.body).to include(ERB::Util.html_escape(I18n.t('invite_move_button', team: account.name)))
      no_validation_error!
    end
  end

  # The one function every door asks (Accounts.last_admin?), and the door that
  # can actually reach it today.
  #
  # `destroy` and `update` carry the same refusal, and both are unreachable
  # through the UI as it stands: removing or demoting yourself is refused for
  # its own reason further up, and anybody else who can work that door is
  # themselves a second full-access admin — which is exactly what makes the
  # target not the last one. They are asserted here as the guard they are
  # (never firing while a second admin exists) plus the predicate itself,
  # because Phase C's self-deletion and any operator-driven account move do
  # reach them.
  describe 'the last administrator' do
    it 'is whoever would leave the account with nobody who can administer it' do
      expect(Accounts.last_admin?(admin)).to be(true)

      second = create(:user, account:)

      expect(Accounts.last_admin?(admin)).to be(false)
      expect(Accounts.last_admin?(second)).to be(false)

      # A read-only admin cannot administer anything, so they do not count as
      # the other administrator.
      second.update!(read_only_at: Time.current)

      expect(Accounts.last_admin?(admin)).to be(true)
      expect(Accounts.last_admin?(second)).to be(false)

      # Neither does an archived one, nor somebody who is not an admin.
      second.update!(read_only_at: nil, archived_at: Time.current)

      expect(Accounts.last_admin?(admin)).to be(true)

      expect(Accounts.last_admin?(create(:user, account:, role: User::EDITOR_ROLE))).to be(false)
    end

    it 'cannot be made read-only, and can be once somebody else can administer the account' do
      expect { post "/users/#{admin.id}/read_only" }.not_to(change { admin.reload.read_only_at })

      expect(response).to redirect_to('/settings/users')
      expect(flash[:alert]).to eq(I18n.t('last_admin_cannot_be_removed'))

      second = create(:user, account:)

      expect { post "/users/#{second.id}/read_only" }.to(change { second.reload.read_only_at }.from(nil))

      expect(flash[:notice]).to eq(I18n.t('user_is_now_read_only'))
    end

    # Review batch 1, F12: the guard read the account the user is being moved
    # TO, because the move had already been assigned by the time it asked. So
    # moving the last admin out of an account — which strands it exactly like
    # archiving them — was allowed.
    #
    # (The door itself — moving somebody to another account — is unreachable
    # today: no ability grants any user a second account, so
    # `Account.accessible_by` never finds one. The guard is asserted where it
    # is asked, and Session 8's operator doors are what will reach it.)
    it 'is judged against the account being left, not the one being moved to' do
      other_account = create(:account)
      create(:user, account: other_account)

      # Assigned exactly the way UsersController#update assigns it, before the
      # guard is asked anything.
      admin.account = other_account

      expect(Accounts.last_admin?(admin, account_id: account.id)).to be(true)
      # Asked the way it used to be — off the row that has already moved — it
      # answers about the destination, which is the wrong account entirely.
      expect(Accounts.last_admin?(admin)).to be(false)
    end

    it 'never gets in the way while a second administrator is there' do
      second = create(:user, account:)

      expect { delete "/users/#{second.id}" }.to(change { second.reload.archived_at }.from(nil))

      third = create(:user, account:)

      expect { put "/users/#{third.id}", params: { user: { role: User::VIEWER_ROLE } } }
        .to(change { third.reload.role }.to(User::VIEWER_ROLE))
    end

    # Review 8: the guard was a check and then, some lines later, a write, with
    # nothing holding the two together. "Unreachable while a second admin
    # exists" is exactly the precondition for the race — two admins acting at
    # the same moment. Each removed the OTHER: both reads saw a second
    # administrator, both writes landed on a different user row, and the
    # account came out the far side with nobody who could invite anyone, change
    # a role or fix its own billing. Only an operator could put that back.
    #
    # The interleaving is simulated the way every other lock race in this suite
    # is (spec/golden/billing_page_spec.rb, spec/golden/consent_version_spec.rb):
    # the concurrent request commits while this one is queued for the account
    # row lock, so the question has to be asked again on the far side of it.
    # There is no such window without the lock: with the old shape the stub
    # never fires at all, because nothing on the path ever took one.
    describe 'two administrators removing each other at the same moment' do
      let!(:second) { create(:user, account:) }

      # The other request, landing in exactly that window: by the time this one
      # gets the lock, the admin doing the racing has already archived
      # themselves out of the account. Committed OUTSIDE the locked
      # transaction, because that is where the other request's write really
      # was — a rolled-back refusal must not take it with it.
      def race_at_the_lock!
        raced = false

        allow_any_instance_of(Account).to receive(:with_lock).and_wrap_original do |original, *args, &block|
          User.where(id: admin.id).update_all(archived_at: Time.current) unless raced
          raced = true

          original.call(*args, &block)
        end
      end

      # Whoever is left has to be able to administer the account tomorrow.
      def administrators
        User.where(account_id: account.id).admins.active.full_access
      end

      it 'refuses the archival that would have emptied the account' do
        race_at_the_lock!

        expect { delete "/users/#{second.id}" }.not_to(change { second.reload.archived_at })

        expect(response).to redirect_to('/settings/users')
        # The racing removal really did commit: without that this example
        # would be proving nothing.
        expect(admin.reload.archived_at).to be_present
        expect(flash[:alert]).to eq(I18n.t('last_admin_cannot_be_removed'))
        expect(administrators.ids).to eq([second.id])
      end

      it 'refuses the demotion that would have emptied the account' do
        race_at_the_lock!

        expect { put "/users/#{second.id}", params: { user: { role: User::VIEWER_ROLE } } }
          .not_to(change { second.reload.role })

        expect(response).to redirect_to('/settings/users')
        # The racing removal really did commit: without that this example
        # would be proving nothing.
        expect(admin.reload.archived_at).to be_present
        expect(flash[:alert]).to eq(I18n.t('last_admin_cannot_be_removed'))
        expect(administrators.ids).to eq([second.id])
      end

      it 'refuses the read-only parking that would have emptied the account' do
        race_at_the_lock!

        expect { post "/users/#{second.id}/read_only" }.not_to(change { second.reload.read_only_at })

        expect(response).to redirect_to('/settings/users')
        # The racing removal really did commit: without that this example
        # would be proving nothing.
        expect(admin.reload.archived_at).to be_present
        expect(flash[:alert]).to eq(I18n.t('last_admin_cannot_be_removed'))
        expect(administrators.ids).to eq([second.id])
      end
    end
  end

  describe 'a downgrade with more people than seats' do
    let!(:recent_admin) { create(:user, account:, current_sign_in_at: 1.hour.ago) }
    let!(:member) { create(:user, account:, role: User::EDITOR_ROLE) }
    let(:row) { create(:account_subscription, account:, access_state: 'active', status: 'active', quantity: 3) }

    before do
      admin.update!(current_sign_in_at: 5.days.ago)
      row
    end

    def downgrade!
      body = JSON.parse(fixture_body('subscription-canceled'))

      StripeBilling::SubscriptionSync.apply!(row, body)

      row.reload
    end

    it 'keeps the most recently signed-in admin, makes everyone else read-only and says so', sidekiq: :inline do
      downgrade!

      expect(Plans.key_for(account.reload)).to eq(Plans::FREE)
      expect(recent_admin.reload.read_only_at).to be_nil
      expect(admin.reload.read_only_at).to be_present
      expect(member.reload.read_only_at).to be_present
      expect(Accounts.users_count(account)).to eq(1)

      mail = deliveries.find { |m| m.subject == 'Your EsignCenter plan now has fewer seats' }

      expect(mail).to be_present
      expect(body_of(mail)).to include(recent_admin.full_name)

      # Applying the same Stripe object again changes nothing and says nothing.
      expect { downgrade! }.not_to(change { User.where(account:).read_only.count })
    end

    it 'leaves a read-only member able to read and download, and unable to create anything' do
      downgrade!
      act_as(member.reload)

      get '/templates'

      expect(response).to have_http_status(:ok)

      expect { post '/templates', params: { template: { name: 'While read-only' } } }
        .not_to change(Template, :count)

      expect(response).to redirect_to(root_path)
    end

    # The machine door for the same person. A parked member keeps their MCP
    # token, and the account behind it can be perfectly healthy — it pays
    # again, and D43 still keeps them parked — so the token guard (which asks
    # about the ACCOUNT) lets the request in and the ability layer is what
    # refuses it. That refusal has to look like every other refusal this door
    # makes: JSON-RPC and 403, never an HTML 500.
    it 'refuses a parked member their own MCP token with 403 JSON and creates nothing', sidekiq: :inline do
      template = create(:template, account:, author: recent_admin, only_field_types: %w[text])

      downgrade!
      # The account pays again; the member stays parked (D43).
      row.update!(access_state: 'active', status: 'manual')
      create(:account_config, account:, key: AccountConfig::ENABLE_MCP_KEY, value: true)

      expect(Plans.key_for(account.reload)).to eq(Plans::PAID)
      expect(member.reload.read_only_at).to be_present

      token = member.mcp_tokens.create!(name: 'Old laptop')
      call = { name: 'send_documents',
               arguments: { template_id: template.id, submitters: [{ email: unique_email }] } }

      expect do
        post '/mcp',
             headers: { 'Authorization' => "Bearer #{token.token}", 'Content-Type' => 'application/json',
                        'Accept' => 'application/json' },
             params: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: call }.to_json
      end.not_to change(Submission, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['error']).to include('code' => -32_603, 'message' => 'Forbidden')
      expect(Submitter.where(account:).count).to eq(0)
    end

    it 'gives a seat back when there is one, and refuses when there is not' do
      downgrade!
      act_as(recent_admin)

      expect { delete "/users/#{member.id}/read_only" }.not_to(change { member.reload.read_only_at })

      expect(flash[:alert]).to eq(I18n.t('seat_limit_free'))

      # A seat exists again: the admin decides who gets it.
      row.update!(access_state: 'active', status: 'manual', quantity: 2)

      expect { delete "/users/#{member.id}/read_only" }.to(change { member.reload.read_only_at }.to(nil))

      expect(flash[:notice]).to eq(I18n.t('user_has_full_access_again'))
      expect(Accounts.users_count(account)).to eq(2)
    end

    # Review batch 1, F7: the kept admin used to be chosen once for the whole
    # billing family, so a linked child with its own people was left with
    # nobody who could administer it — ever.
    it 'keeps an administrator for every account in the family' do
      child = create(:account, linked_account_account: AccountLinkedAccount.new(account_type: :linked, account:))
      child_admin = create(:user, account: child, current_sign_in_at: 2.days.ago)
      child_editor = create(:user, account: child, role: User::EDITOR_ROLE)

      downgrade!

      expect(recent_admin.reload.read_only_at).to be_nil
      expect(child_admin.reload.read_only_at).to be_nil
      expect(child_editor.reload.read_only_at).to be_present
      expect(Accounts.last_admin?(child_admin.reload)).to be(true)
    end

    # F4: a pending invitation on a plan with no room for it is a seat nobody
    # can take — left alone, accepting it makes a second full-access member.
    it 'cancels the invitations the plan can no longer hold, and says so', sidekiq: :inline do
      pending_invite = create(:account_invite, account:)

      downgrade!

      expect(pending_invite.reload.revoked_at).to be_present
      expect(pending_invite.released_at).to be_present
      expect(pending_invite).not_to be_pending

      mail = deliveries.find { |m| m.subject == 'Your EsignCenter plan now has fewer seats' }

      expect(body_of(mail)).to include('1 pending invitation was cancelled')
    end

    # F2 (review 8): the manual doors were brought under the account's row
    # lock so two administrators could not park each other into an account
    # with nobody in charge. The AUTOMATIC downgrade parks people too, and it
    # was not: it chose who to keep and decided who was safe to park with no
    # lock at all. With administrators A and B, it could decide to keep A and
    # park B; B could then park A through the correctly locked manual door
    # (A really is not the last administrator at that moment); and the
    # downgrade would then park B on its stale decision, leaving nobody who
    # can invite anyone, change a role or fix the account's billing.
    describe 'racing the manual last-admin guard' do
      def administrators
        User.where(account_id: account.id).admins.active.full_access
      end

      # The manual park, committed just before the downgrade takes the
      # account row lock — which, with the lock in place, is the only moment
      # the other request can land in: Postgres serialises the two, so the
      # manual write is either entirely before this lock or entirely after
      # it. Committed OUTSIDE the locked transaction, the way the "two
      # administrators removing each other at the same moment" group above
      # does it, because that is where the other request's write really was.
      def park_the_keeper_at_the_lock!
        allow(BillingLifecycle).to receive(:with_seat_family_lock).and_wrap_original do |original, *args, &block|
          User.where(id: recent_admin.id).update_all(read_only_at: Time.current)

          original.call(*args, &block)
        end
      end

      # The fix itself: the choice and the demotion both happen inside the
      # account rows' lock, which is what makes the interleaving above
      # impossible rather than merely unlikely. Asserted directly, because a
      # single-connection spec cannot make two requests genuinely contend —
      # it can only prove that the decision is taken where a contending
      # request would have to wait for it.
      it 'chooses the keepers and parks the rest under the account row lock' do
        depth = 0
        chose_under_lock = nil
        parked_under_lock = nil
        statements = []

        subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
          statements << payload[:sql].to_s
        end

        allow(BillingLifecycle).to receive(:with_seat_family_lock).and_wrap_original do |original, *args, &block|
          depth += 1

          begin
            original.call(*args, &block)
          ensure
            depth -= 1
          end
        end

        allow(BillingLifecycle).to receive(:admins_to_keep).and_wrap_original do |original, *args|
          chose_under_lock = depth.positive?

          original.call(*args)
        end

        allow(BillingLifecycle).to receive(:demote_members!).and_wrap_original do |original, *args|
          parked_under_lock = depth.positive?

          original.call(*args)
        end

        downgrade!

        expect(chose_under_lock).to be(true)
        expect(parked_under_lock).to be(true)
        # And it really was a row lock on the accounts table, taken in a
        # fixed order so two overlapping families cannot deadlock.
        expect(statements).to include(a_string_matching(/FROM "accounts".*ORDER BY "accounts"\."id".*FOR UPDATE/m))
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      it 'keeps a working administrator when the manual park lands first', sidekiq: :inline do
        park_the_keeper_at_the_lock!

        downgrade!

        # The racing park really did commit: without that this example would
        # be proving nothing.
        expect(recent_admin.reload.read_only_at).to be_present

        # The downgrade re-read the account under the lock, found the admin
        # it would have kept already parked, and kept the other one instead.
        expect(administrators.ids).to eq([admin.id])
        expect(admin.reload.read_only_at).to be_nil
        expect(member.reload.read_only_at).to be_present
        expect(Accounts.users_count(account)).to eq(1)
      end

      it 'refuses the manual park when the downgrade got there first' do
        downgrade!

        expect(administrators.ids).to eq([recent_admin.id])

        act_as(recent_admin.reload)

        expect { post "/users/#{recent_admin.id}/read_only" }
          .not_to(change { recent_admin.reload.read_only_at })

        expect(response).to redirect_to('/settings/users')
        expect(flash[:alert]).to eq(I18n.t('last_admin_cannot_be_removed'))
        expect(administrators.ids).to eq([recent_admin.id])
      end
    end

    # F11: everybody may manage their own user row — that is how a password
    # gets changed — and that included clearing their own read-only mark.
    #
    # Loop 2 (G1) put a second refusal in front of it: a parked member has no
    # `:administer` on the account at all, so the page gate now answers first
    # and the self-guard behind it is the inner line. Both are asserted —
    # what matters is that they cannot un-park themselves.
    it 'never lets a parked admin hand themselves the seat back' do
      downgrade!
      act_as(admin.reload)

      expect { delete "/users/#{admin.id}/read_only" }.not_to(change { admin.reload.read_only_at })

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to be_present
    end

    it 'never marks anybody read-only while the account is only suspended for billing' do
      body = JSON.parse(fixture_body('subscription-past_due')).merge('status' => 'unpaid')

      StripeBilling::SubscriptionSync.apply!(row, body)

      expect(row.reload.access_state).to eq('suspended')
      expect(User.where(account:).read_only.count).to eq(0)
    end
  end

  describe 'the billing page' do
    it 'names the seats, who is using them and the invitations holding one' do
      stripe_paid!(account, seats: 4)
      create(:account_invite, account:)

      get '/settings/billing'

      expect(response).to have_http_status(:ok)
      expect(doc.at('[data-billing-seats-in-use]').text).to include(
        I18n.t('billing_seats_summary_pending', seats: 4, in_use: 2, pending: 1)
      )
      expect(doc.at('[data-billing-seats-in-use]').at('a')['href']).to eq('/settings/users')
    end
  end

  # The accept link as the invitee receives it. Rows read back from the
  # database never carry a raw token — that is the point of storing only its
  # digest — so an invitation created through the real door is opened the way
  # its recipient opens it: out of the email.
  def token_from_mail
    body_of(deliveries.last)[%r{/invites/([A-Za-z0-9_-]+)}, 1]
  end

  # The mail is multipart by the time the interceptor is done, and
  # quoted-printable wraps long lines: an accept link read off the raw encoded
  # body would be cut in half.
  def body_of(mail)
    (mail.html_part || mail.text_part || mail.body).decoded
  end
end
