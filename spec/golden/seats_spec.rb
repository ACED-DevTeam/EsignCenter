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
    # `pending_update`. The seat is not bought, so nothing is promised.
    it 'reserves nothing when Stripe parks the change for a payment step' do
      stub_invoice_preview(amount_cents: 634)
      stub_subscription_update(subscription_a, quantity: 2,
                                               overrides: { 'pending_update' => { 'expires_at' => 1_788_411_000 } })

      invite('new-hire@example.com')

      expect { post '/account_invites', params: { offer: offer_token } }
        .not_to change(AccountInvite, :count)

      expect(response).to redirect_to('/settings/users')
      expect(flash[:alert]).to eq(I18n.t('seat_add_needs_payment_action'))
      expect(account.account_subscription.reload.quantity).to eq(1)
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
    it 'takes back a parked seat the customer completed in Stripe\'s own portal' do
      row = stripe_paid!(account, seats: 1)
      stub_invoice_preview(amount_cents: 634)
      stub_subscription_update(subscription_a, quantity: 2,
                                               overrides: { 'pending_update' => { 'expires_at' => 1_788_411_000 } })

      invite('new-hire@example.com')

      expect { post '/account_invites', params: { offer: offer_token } }.not_to change(AccountInvite, :count)

      expect(flash[:alert]).to eq(I18n.t('seat_add_needs_payment_action'))

      # Days later the customer finishes the card step in Stripe's own portal
      # and the subscription really does bill for two. Nobody was ever invited
      # into that seat and nobody ever will be, so applying that news asks for
      # it back — from a JOB, once the webhook's own transaction is over, and
      # never with an outbound call from inside the lock that is applying it.
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

      expect(invite_row).to be_collision
      expect(invite_row.collision_user).to eq(other_user)
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
