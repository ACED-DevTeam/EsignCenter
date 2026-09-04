# frozen_string_literal: true

# D43's other half: what a downgrade must NEVER do, and what deleting an
# account actually does.
#
# The rule this file protects, in one sentence: **a downgrade never purges.**
# Dropping from the paid plan to the free one changes what you may CREATE
# next and nothing else — every document, template, person, counter and
# setting stays exactly where it was, readable, downloadable and exportable.
# The only thing in this application that destroys data is the deliberate
# 90-day deletion at the bottom of this file, and the year-long dormancy rule
# beside it.
#
# Everything here is driven through the real doors: a signer's own PUT for a
# completion (SigningHelpers#complete!) under `sidekiq: :inline`, real HTTP
# requests for every page, and the ONE Stripe mapping every Stripe door
# shares (StripeBilling::SubscriptionSync.apply!) fed a real CLI capture for
# the downgrade. No metering row is ever inserted by hand.
RSpec.describe 'A downgrade to the free plan', type: :request do # rubocop:disable RSpec/MultipleDescribes
  let(:account) { create(:account, :paid) }
  let(:admin) { create(:user, account:) }
  let(:template) { create(:template, account:, author: admin, only_field_types: %w[text]) }
  let(:row) { account.account_subscription }

  before do
    platform_certificate!
    ActionMailer::Base.deliveries.clear
  end

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
    "signer-#{SecureRandom.hex(4)}@example.com"
  end

  def send_one(email: unique_email)
    Submissions.create_from_emails(template:, user: admin, emails: email, source: :invite,
                                   mark_as_sent: true).sole
  end

  # What Stripe actually says when a subscription ends, through the one
  # mapping every Stripe door in the app shares.
  def downgrade!
    StripeBilling::SubscriptionSync.apply!(row, JSON.parse(fixture_body('subscription-canceled')))

    row.reload
    account.reload
  end

  def fixture_body(name)
    Rails.root.join("spec/fixtures/stripe/#{name}.json").read
  end

  # Every table the deletion inventory would empty, counted before and after,
  # so "nothing was deleted" is a measurement rather than a hope.
  def data_counts
    template_ids = Template.where(account_id: account.id).ids

    { templates: template_ids.size,
      submissions: Submission.where(account_id: account.id).count,
      submitters: Submitter.where(account_id: account.id).count,
      completed_submitters: CompletedSubmitter.where(account_id: account.id).count,
      submission_events: SubmissionEvent.where(account_id: account.id).count,
      users: User.where(account_id: account.id).count,
      blobs: ActiveStorage::Attachment.where(record_type: 'Template', record_id: template_ids).count,
      counters: AccountCounter.where(account_id: account.id).count }
  end

  describe 'never deletes anything (D43)' do
    it 'keeps every document readable, downloadable and exportable after the subscription ends',
       sidekiq: :inline do
      submission = send_one
      complete!(submission.submitters.first)

      before_counts = data_counts

      downgrade!

      expect(Plans.key_for(account)).to eq(Plans::FREE)
      expect(data_counts).to eq(before_counts)
      # The row itself survives too — the money history is not deleted by a
      # downgrade either, only its access state moves.
      expect(row.access_state).to eq('cancelled')

      act_as(admin)

      get '/templates'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(template.name))

      get "/submissions/#{submission.id}"

      expect(response).to have_http_status(:ok)

      get "/submissions/#{submission.id}/download"

      expect(response).to have_http_status(:ok)
      # The body is the list of signed-document URLs the download button uses.
      expect(response.parsed_body).to be_present
      expect(response.parsed_body.first).to include('sample-document.pdf')

      get "/templates/#{template.id}/submissions_export.csv"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(submission.submitters.first.email)
    end

    # Counters are PROSPECTIVE: the five completions bought and used on the
    # paid plan still count against the free month they happened in, so a
    # downgrade is not a way to get another five. What it must not do is take
    # those five documents away.
    it 'keeps the completions already counted, refuses the next send, and still reads the old documents',
       sidekiq: :inline do
      submissions = Array.new(Quotas::Limits::FREE_COMPLETIONS_PER_MONTH) do
        submission = send_one
        complete!(submission.submitters.first)
        submission
      end

      expect(Quotas.completions_this_month(account)).to eq(Quotas::Limits::FREE_COMPLETIONS_PER_MONTH)

      downgrade!

      expect(Quotas.completions_this_month(account)).to eq(Quotas::Limits::FREE_COMPLETIONS_PER_MONTH)
      expect { Quotas.assert_can_create_submissions!(account) }
        .to raise_error(Quotas::LimitReached) { |e| expect(e.reason).to eq(:completions) }

      act_as(admin)

      expect { post "/templates/#{template.id}/submissions", params: { emails: unique_email, send_email: '1' } }
        .not_to change(Submission, :count)

      # And every one of the five is still there to read and download.
      submissions.each do |submission|
        get "/submissions/#{submission.id}/download"

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to be_present
      end
    end

    # Phase B parks the extra people read-only when the seats go. Paying
    # again does NOT hand the seats back on its own: who holds a seat is the
    # admin's decision, and quietly restoring four people would bill for four
    # people nobody asked for.
    it 'leaves read-only members read-only when the account subscribes again', sidekiq: :inline do
      recent_admin = create(:user, account:, current_sign_in_at: 1.hour.ago)
      member = create(:user, account:, role: User::EDITOR_ROLE)

      admin.update!(current_sign_in_at: 5.days.ago)
      row.update!(quantity: 3)

      downgrade!

      expect(recent_admin.reload.read_only_at).to be_nil
      expect(admin.reload.read_only_at).to be_present
      expect(member.reload.read_only_at).to be_present

      StripeBilling::SubscriptionSync.apply!(row, JSON.parse(fixture_body('subscription-active')))

      expect(Plans.key_for(account.reload)).to eq(Plans::PAID)
      expect(admin.reload.read_only_at).to be_present
      expect(member.reload.read_only_at).to be_present
    end
  end

  # A template built while paid goes on working after the downgrade, for the
  # signers already holding it and for the admin re-saving it. The rule lives
  # in lib/templates/assert_entitled_fields.rb: with a BASELINE, only what a
  # save INTRODUCES is refused, so the conditions already on the row may stay.
  describe 'documents already in flight keep their paid behaviour' do
    # Two text fields, and the SECOND carries a condition built while the
    # account was paid: it is shown only while the first is empty. The signer
    # fills the first, so the conditional field is hidden and not required —
    # which is the point: the condition is still being EVALUATED after the
    # downgrade (lib/templates/assert_entitled_fields.rb is never consulted at
    # signing time, D43).
    let(:conditional_template) do
      create(:template, account:, author: admin, attachment_count: 2, only_field_types: %w[text]).tap do |record|
        fields = record.fields.deep_dup
        fields.last['conditions'] = [{ 'field_uuid' => fields.first['uuid'], 'action' => 'empty' }]
        record.update!(fields:)
      end
    end

    # The builder's own door: a JSON body with no Accept header, exactly as
    # spec/golden/gating_spec.rb drives it.
    def save_fields!(template, fields)
      put "/templates/#{template.id}",
          params: { template: { fields:, schema: template.schema, submitters: template.submitters } }.to_json,
          headers: { 'CONTENT_TYPE' => 'application/json' }

      template.reload
    end

    it 'serves the conditions to an in-flight signer and meters the completion', sidekiq: :inline do
      submission = Submissions.create_from_emails(template: conditional_template, user: admin,
                                                  emails: unique_email, source: :invite,
                                                  mark_as_sent: true).sole
      submitter = submission.submitters.first
      condition = conditional_template.fields.last['conditions']

      downgrade!

      expect(Plans.key_for(account)).to eq(Plans::FREE)

      anonymous!

      get "/s/#{submitter.slug}"

      expect(response).to have_http_status(:ok)
      # The form is handed the fields as JSON; the condition has to be in it,
      # or the signer's browser would show a field that should be hidden.
      expect(response.body).to include(CGI.escapeHTML(condition.first['field_uuid']))
      expect(Submissions.filtered_conditions_fields(submitter).find { |f| f['conditions'].present? }['conditions'])
        .to eq(condition)

      complete!(submitter)

      expect(submitter.reload.completed_at).to be_present
      expect(Quotas.completions_this_month(account)).to eq(1)
    end

    it 'still saves the template with the conditions it already had, and refuses a new one' do
      legacy = conditional_template.fields.last['conditions']

      downgrade!
      act_as(admin)

      fields = conditional_template.fields.deep_dup
      fields.first['name'] = 'Renamed after the downgrade'

      save_fields!(conditional_template, fields)

      expect(response).to have_http_status(:ok)
      expect(conditional_template.fields.first['name']).to eq('Renamed after the downgrade')
      expect(conditional_template.fields.last['conditions']).to eq(legacy)

      # A SECOND field gaining a condition is new conditional logic, and the
      # free plan does not have it.
      fields = conditional_template.fields.deep_dup
      fields.first['conditions'] = [{ 'field_uuid' => fields.last['uuid'], 'action' => 'not_empty' }]

      save_fields!(conditional_template, fields)

      expect(response).to have_http_status(:forbidden)
      expect(conditional_template.fields.first['conditions']).to be_nil
      expect(conditional_template.fields.last['conditions']).to eq(legacy)
    end
  end
end

# Deleting an account on purpose (D43): the 90-day window, and the purge at
# the end of it.
RSpec.describe 'Deleting an account', type: :request do
  include_context 'with a Stripe test account'

  let(:account) { create(:account) }
  let(:admin) { create(:user, account:, password: 'correct horse battery') }
  let(:template) { create(:template, account:, author: admin, only_field_types: %w[text]) }
  let(:deliveries) { ActionMailer::Base.deliveries }

  before do
    platform_certificate!
    deliveries.clear
    # The rate-limit store is an in-memory singleton that outlives an example,
    # and rolled-back user ids repeat — so without this an example inherits
    # the previous one's spent budget.
    RateLimit.store.clear
  end

  def act_as(user)
    sign_out(:user)
    reset!
    sign_in(user)
  end

  def unique_email
    "signer-#{SecureRandom.hex(4)}@example.com"
  end

  def send_one(email: unique_email)
    Submissions.create_from_emails(template:, user: admin, emails: email, source: :invite,
                                   mark_as_sent: true).sole
  end

  def request_deletion!(password: 'correct horse battery', confirm: '1', confirmation_code: nil)
    delete '/settings/account', params: { password:, confirm:, confirmation_code: }.compact

    account.reload
  end

  describe 'the confirmation' do
    before { act_as(admin) }

    it 'refuses a wrong password, and an unticked box, and changes nothing' do
      request_deletion!(password: 'not my password')

      expect(response).to redirect_to(settings_account_path)
      expect(flash[:alert]).to eq(I18n.t('account_deletion_wrong_password'))
      expect(account.deletion_requested_at).to be_nil
      expect(account.suspended_at).to be_nil

      request_deletion!(confirm: nil)

      expect(flash[:alert]).to eq(I18n.t('account_deletion_confirmation_required'))
      expect(account.reload.deletion_requested_at).to be_nil
    end

    # The screen itself: the card, the list of consequences, the password
    # field and the typed confirmation — and, once the deletion is scheduled,
    # the way back instead of the way out.
    it 'shows the danger zone with everything that is about to happen, and the way back afterwards' do
      get '/settings/account'

      expect(response).to have_http_status(:ok)

      doc = Nokogiri::HTML(response.body)

      expect(doc.at('[data-danger-zone]')).to be_present
      expect(doc.at('[data-delete-account-button]').text.strip).to eq(I18n.t('delete_my_account'))

      modal = doc.at('[data-delete-account-modal]')

      expect(modal).to be_present
      expect(modal.css('li').map { |li| li.text.strip }).to include(I18n.t('account_deletion_bullet_subscription'),
                                                                    I18n.t('account_deletion_bullet_read_only'),
                                                                    I18n.t('account_deletion_bullet_verify'))
      expect(modal.at('[data-delete-account-password]')).to be_present
      expect(modal.at('[data-delete-account-confirm]')).to be_present
      expect(modal.at('form')['action']).to eq(settings_account_path)
      expect(response.body).not_to include('translation missing')

      account.update!(deletion_requested_at: Time.current, purge_scheduled_for: 90.days.from_now)

      get '/settings/account'

      doc = Nokogiri::HTML(response.body)

      expect(doc.at('[data-deletion-scheduled]')).to be_present
      expect(doc.at('[data-delete-account-button]')).to be_nil
      expect(doc.at('[data-cancel-deletion-button]')).to be_present
    end

    # The password check goes through Devise's own gate (review batch 2, K12).
    # Without it this door was an unthrottled password oracle that left no
    # trace on the user row at all: guesses here never counted towards the
    # lock that guards every other password field in the app.
    it 'counts a wrong password against the Devise lock' do
      expect { request_deletion!(password: 'not my password') }
        .to change { admin.reload.failed_attempts }.from(0).to(1)

      request_deletion!(password: 'still not it')

      expect(admin.reload.failed_attempts).to eq(2)

      # The count is Devise's to clear — it resets on the next successful
      # sign-in, not here — and the right password still works.
      request_deletion!

      expect(account.deletion_requested_at).to be_present
    end

    # Two presses of one button are one decision (review batch 2, K11). The
    # "was it already pending?" question used to be asked before the row was
    # locked, so both requests answered "no" and both mailed every
    # administrator that their account was being deleted.
    it 'sends one confirmation email however many times the button is pressed', sidekiq: :inline do
      # A STALE object, loaded before the first request — which is the only
      # way to reproduce what two simultaneous presses actually do (review
      # batch 2, P3). Going through the controller twice proves nothing: the
      # second request re-reads the row from scratch and short-circuits on it,
      # so the in-lock re-read is never the thing being tested.
      stale = Account.find(account.id)

      expect(stale.deletion_requested_at).to be_nil

      request_deletion!

      first_date = account.purge_scheduled_for

      expect(first_date).to be_present

      # The second press is holding the account as it looked BEFORE the first
      # one landed. Only the re-read inside the row lock stops it mailing
      # every administrator a second time and cancelling at Stripe again.
      Accounts::Deletion.request!(stale, requested_by: admin)

      expect(account.reload.purge_scheduled_for).to eq(first_date)
      expect(deliveries.count { |m| m.subject.include?('scheduled for deletion') }).to eq(1)
    end

    it 'refuses on an internal account, and never shows the card there' do
      internal = create(:account, :internal)
      internal_admin = create(:user, account: internal, password: 'correct horse battery')

      act_as(internal_admin)

      get '/settings/account'

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).at('[data-danger-zone]')).to be_nil

      delete '/settings/account', params: { password: 'correct horse battery', confirm: '1' }

      expect(flash[:alert]).to eq(I18n.t('account_deletion_not_available'))
      expect(internal.reload.deletion_requested_at).to be_nil
    end
  end

  # Who may end the company's account (review batch 2, K8). `:administer` is
  # granted by Ability#admin_abilities, which every role that is not
  # viewer/editor falls into — the API-only `integration` role included — so
  # the ability alone was not the answer to this question.
  describe 'who may ask for the deletion' do
    it 'refuses an integration robot, an editor, a viewer and an admin parked read-only' do
      # 'integration' is the API-only role: not one of User::ROLES, and
      # therefore one of the "any other role" cases admin_abilities hands
      # `:administer` to.
      refused = { integration: create(:user, account:, role: 'integration'),
                  editor: create(:user, account:, role: User::EDITOR_ROLE),
                  viewer: create(:user, account:, role: User::VIEWER_ROLE),
                  parked: create(:user, account:, role: User::ADMIN_ROLE, read_only_at: Time.current) }

      # A deletion really is pending, so `cancel_deletion` reaches its own
      # refusal rather than the "nothing is scheduled" short-circuit — the
      # door being probed is the one that would UNDO a deletion (P4).
      account.update!(deletion_requested_at: Time.current, purge_scheduled_for: 90.days.from_now)

      refused.each do |who, user|
        act_as(user)

        delete '/settings/account', params: { password: 'password', confirm: '1' }

        expect(response).to redirect_to(root_path), "#{who} was not refused"
        expect(flash[:alert]).to be_present, "#{who} was refused without saying why"
        expect(account.reload.deletion_requested_by_id).to be_nil, "#{who} scheduled a deletion"

        post '/settings/account/cancel_deletion'

        expect(response).to redirect_to(root_path), "#{who} reached cancel_deletion"
        expect(account.reload.deletion_requested_at).to be_present, "#{who} cancelled a deletion"

        post '/settings/account/deletion_code'

        expect(response).to redirect_to(root_path), "#{who} reached deletion_code"
        # `sidekiq: :inline` is what makes this assertion mean anything: an
        # enqueued-but-never-run mailer would look identical to no mail at all.
        expect(deliveries).to be_empty, "#{who} caused mail to be sent"
        expect(account.reload.deletion_code_digest).to be_nil, "#{who} was issued a code"
      end
    end

    # An operator impersonating a customer administrator is signed in as
    # THEMSELVES: it is the operator's password and the operator's mailbox
    # that would confirm this, and ending a customer's company on the
    # operator's own credentials is what Session 8's impersonation contract
    # forbids (review batch 2, P6).
    #
    # Driven through the app's own impersonation door — POST /testing_account,
    # the only one that exists before Session 8's operator console — so what
    # is proved is Pretender's real `true_user != current_user` state and not
    # a stub. The account kind here is incidental: the point is that the
    # refusal arrives BEFORE any other check the doors make.
    it 'refuses every deletion door while impersonating somebody else', sidekiq: :inline do
      internal = create(:account, :internal)
      internal_admin = create(:user, account: internal, password: 'correct horse battery')

      act_as(internal_admin)

      post '/testing_account'

      expect(response).to have_http_status(:redirect)

      delete '/settings/account', params: { password: 'correct horse battery', confirm: '1' }

      expect(flash[:alert]).to eq(I18n.t('account_deletion_not_while_impersonating'))

      post '/settings/account/deletion_code'

      expect(flash[:alert]).to eq(I18n.t('account_deletion_not_while_impersonating'))

      post '/settings/account/cancel_deletion'

      expect(flash[:alert]).to eq(I18n.t('account_deletion_not_while_impersonating'))
      expect(deliveries).to be_empty
      expect(Account.where.not(deletion_requested_at: nil)).to be_empty
    end
  end

  # The confirmation code is a credential: six digits that, with nothing else,
  # schedule the destruction of a company's account. It was going into the
  # production log in plain text on every attempt (review batch 2, P2).
  describe 'what reaches the log' do
    let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

    it 'never logs the confirmation code, and still logs the ordinary parameters' do
      filtered = filter.filter('confirmation_code' => '123456', 'password' => 'hunter2',
                               'confirm' => '1', 'account' => { 'name' => 'Acme' })

      expect(filtered['confirmation_code']).to eq('[FILTERED]')
      expect(filtered['password']).to eq('[FILTERED]')
      # Not over-broad: the things a person needs in the log are still there.
      expect(filtered['confirm']).to eq('1')
      expect(filtered.dig('account', 'name')).to eq('Acme')
    end
  end

  # Two ways to prove it is them, and the second one is the reason this was
  # rewritten (review batch 2, K9): OmniAuth gives every Google user a random
  # `Devise.friendly_token` password, so the old "you have no password, type
  # the account name instead" branch could never run — and a Google-only
  # administrator, whose password is a token nobody has ever seen, could not
  # confirm a deletion at all.
  describe 'confirming with an emailed code' do
    # Exactly what OmniauthCallbacksController leaves behind.
    let(:google_admin) { create(:user, account:, password: Devise.friendly_token) }

    before { act_as(google_admin) }

    # The code is read out of the BODY, because it is no longer in the subject
    # — a subject line shows on a lock screen and in every mail client's list
    # view, and this one is a credential (review batch 2, P5).
    def emailed_code
      post '/settings/account/deletion_code'

      mail = deliveries.last

      expect(mail).to be_present
      expect(mail.subject).to eq('Your EsignCenter account deletion code')
      expect(mail.subject).not_to match(/\d{6}/)
      expect(mail.to).to contain_exactly(google_admin.email)

      # The delivered message is multipart (HtmlToPlainTextInterceptor adds the
      # text part), so the parts are decoded rather than read off the wire.
      body = mail.multipart? ? mail.parts.map(&:decoded).join("\n") : mail.body.decoded

      body[/>(\d{6})</, 1] || body[/\b(\d{6})\b/, 1]
    end

    it 'emails a six-digit code, stores only its digest, and accepts it once', sidekiq: :inline do
      code = emailed_code

      expect(code).to be_present
      # The database holds a hash, never the code.
      expect(account.reload.deletion_code_digest).to be_present
      expect(account.deletion_code_digest).not_to include(code)
      expect(account.deletion_code_user_id).to eq(google_admin.id)

      delete '/settings/account', params: { confirmation_code: code, confirm: '1' }

      expect(account.reload.deletion_requested_at).to be_present
      expect(account.suspension_reason).to eq('deletion')
      # Consumed: nothing is left to replay.
      expect(account.deletion_code_digest).to be_nil
    end

    # The fault the stored design exists to close: a derived code stayed valid
    # after it had been used, so anyone who saw it once — over a shoulder, in
    # a forwarded email, in a log — could use it again (P5).
    it 'refuses the same code a second time', sidekiq: :inline do
      code = emailed_code

      delete '/settings/account', params: { confirmation_code: code, confirm: '1' }

      expect(account.reload.deletion_requested_at).to be_present

      post '/settings/account/cancel_deletion'

      expect(account.reload.deletion_requested_at).to be_nil

      delete '/settings/account', params: { confirmation_code: code, confirm: '1' }

      expect(flash[:alert]).to eq(I18n.t('account_deletion_wrong_code'))
      expect(account.reload.deletion_requested_at).to be_nil
    end

    it 'invalidates the old code as soon as a new one is issued', sidekiq: :inline do
      first = emailed_code
      second = emailed_code

      expect(second).not_to eq(first)

      delete '/settings/account', params: { confirmation_code: first, confirm: '1' }

      expect(flash[:alert]).to eq(I18n.t('account_deletion_wrong_code'))
      expect(account.reload.deletion_requested_at).to be_nil

      delete '/settings/account', params: { confirmation_code: second, confirm: '1' }

      expect(account.reload.deletion_requested_at).to be_present
    end

    it 'refuses a wrong code, and a code that has expired', sidekiq: :inline do
      code = emailed_code

      delete '/settings/account', params: { confirmation_code: '000000', confirm: '1' }

      expect(flash[:alert]).to eq(I18n.t('account_deletion_wrong_code'))
      expect(account.reload.deletion_requested_at).to be_nil

      travel_to((Accounts::DeletionCodes::TTL + 1.minute).from_now) do
        delete '/settings/account', params: { confirmation_code: code, confirm: '1' }
      end

      expect(flash[:alert]).to eq(I18n.t('account_deletion_wrong_code'))
      expect(account.reload.deletion_requested_at).to be_nil
      # An expired code is thrown away rather than left to be attacked.
      expect(account.deletion_code_digest).to be_nil
    end

    # Counted in a COLUMN, not in Redis: the budget cannot fail open (P5).
    it 'stops guessing after five tries and throws the code away', sidekiq: :inline do
      code = emailed_code

      Accounts::DeletionCodes::MAX_ATTEMPTS.times do
        delete '/settings/account', params: { confirmation_code: '000000', confirm: '1' }

        expect(flash[:alert]).to eq(I18n.t('account_deletion_wrong_code'))
      end

      expect(account.reload.deletion_code_attempts).to eq(Accounts::DeletionCodes::MAX_ATTEMPTS)

      # The sixth guess is refused as a guess, not as a wrong code — and the
      # real code is destroyed with it, so the budget cannot simply be waited
      # out.
      delete '/settings/account', params: { confirmation_code: code, confirm: '1' }

      expect(flash[:alert]).to eq(I18n.t('too_many_attempts'))
      expect(account.reload.deletion_code_digest).to be_nil
      expect(account.deletion_requested_at).to be_nil

      # And the code really is dead: presenting it again proves nothing.
      delete '/settings/account', params: { confirmation_code: code, confirm: '1' }

      expect(account.reload.deletion_requested_at).to be_nil
    end

    it 'counts the attempts durably, so an unreachable Redis cannot lift the limit', sidekiq: :inline do
      emailed_code

      3.times { delete '/settings/account', params: { confirmation_code: '000000', confirm: '1' } }

      expect(account.reload.deletion_code_attempts).to eq(3)
    end

    # Asking for a code sends mail and resets the guess budget, so the asking
    # is throttled too (review batch 2, P8).
    it 'stops a fourth request for a code inside the window', sidekiq: :inline do
      Accounts::DeletionCodes::MAX_ISSUES.times { post '/settings/account/deletion_code' }

      expect(deliveries.size).to eq(Accounts::DeletionCodes::MAX_ISSUES)

      post '/settings/account/deletion_code'

      expect(flash[:alert]).to eq(I18n.t('too_many_attempts'))
      expect(deliveries.size).to eq(Accounts::DeletionCodes::MAX_ISSUES)
    end

    # Asking for a fresh code used to reset the budget, so five guesses could
    # be turned into fifteen by pressing the button again — and the only thing
    # in the way was a Redis throttle, which fails open (review batch 2, R6).
    it 'does not hand back guesses when a new code is issued', sidekiq: :inline do
      emailed_code

      3.times { delete '/settings/account', params: { confirmation_code: '000000', confirm: '1' } }

      expect(account.reload.deletion_code_attempts).to eq(3)

      code = emailed_code

      # A fresh CODE, not a fresh budget.
      expect(account.reload.deletion_code_attempts).to eq(3)

      2.times { delete '/settings/account', params: { confirmation_code: '000000', confirm: '1' } }

      delete '/settings/account', params: { confirmation_code: code, confirm: '1' }

      expect(flash[:alert]).to eq(I18n.t('too_many_attempts'))
      expect(account.reload.deletion_requested_at).to be_nil
    end

    # And the window does run out, so an honest person who mistyped twice this
    # morning is not locked out this afternoon.
    it 'starts the budget again once the window has passed', sidekiq: :inline do
      emailed_code

      3.times { delete '/settings/account', params: { confirmation_code: '000000', confirm: '1' } }

      expect(account.reload.deletion_code_attempts).to eq(3)

      travel_to((Accounts::DeletionCodes::ATTEMPT_WINDOW + 1.minute).from_now) do
        code = emailed_code

        expect(account.reload.deletion_code_attempts).to eq(0)

        delete '/settings/account', params: { confirmation_code: code, confirm: '1' }

        expect(account.reload.deletion_requested_at).to be_present
      end
    end

    it 'says what is missing when neither proof is given' do
      delete '/settings/account', params: { confirm: '1' }

      expect(flash[:alert]).to eq(I18n.t('account_deletion_proof_required'))
      expect(account.reload.deletion_requested_at).to be_nil
    end
  end

  describe 'the 90-day window' do
    before do
      create(:account_subscription, account:, access_state: 'active', status: 'active',
                                    stripe_subscription_id: 'sub_1UBSbL4rEeOqtLcXAD6ynIIK',
                                    stripe_customer_id: 'cus_VBqHCUoJle1zGV')
    end

    # Both Stripe calls the cancel makes, and they are asserted separately:
    # the metadata write carries the AUTHORITY (only a secret key can make
    # it) and the cancel carries the human-readable comment. A cancel that
    # skipped the marker would hit no stub at all.
    def stub_deletion_cancel
      url = %r{\Ahttps://api\.stripe\.com/v1/subscriptions/sub_1UBSbL4rEeOqtLcXAD6ynIIK}

      mark = stub_request(:post, url)
             .with(body: hash_including('metadata' => hash_including(
               StripeBilling::DUPLICATE_CANCEL_METADATA_KEY => StripeBilling::ACCOUNT_DELETION_METADATA
             )))
             .to_return(status: 200, body: { id: 'sub_1UBSbL4rEeOqtLcXAD6ynIIK', object: 'subscription' }.to_json,
                        headers: { 'Content-Type' => 'application/json' })

      # A Stripe cancel is a DELETE, and the gem puts its parameters in the
      # QUERY STRING rather than a body — matching on a body here would match
      # nothing and quietly prove nothing.
      comment = { 'comment' => StripeBilling::ACCOUNT_DELETION_MARKER }
      cancel = stub_request(:delete, url)
               .with(query: hash_including('cancellation_details' => comment))
               .to_return(status: 200, body: fixture_body('subscription-canceled'),
                          headers: { 'Content-Type' => 'application/json' })

      [mark, cancel]
    end

    it 'freezes the account, cancels the subscription at Stripe and emails every admin', sidekiq: :inline do
      second_admin = create(:user, account:)
      mark, cancel = stub_deletion_cancel

      act_as(admin)
      travel_to Time.utc(2026, 9, 4, 12) do
        request_deletion!
      end

      expect(response).to redirect_to(settings_account_path)
      expect(account.deletion_requested_at).to be_present
      expect(account.purge_scheduled_for.to_date).to eq(Date.new(2026, 12, 3))
      expect(account.deletion_requested_by_id).to eq(admin.id)
      expect(account.suspended_at).to be_present
      expect(account.suspension_reason).to eq('deletion')

      expect(mark).to have_been_requested
      expect(cancel).to have_been_requested

      mail = deliveries.find { |m| m.subject.include?('scheduled for deletion') }

      expect(mail).to be_present
      expect(mail.to).to contain_exactly(admin.email, second_admin.email)
      expect(mail.body.encoded).to include('3 December 2026')
    end

    it 'keeps signing in, reading and exporting open while refusing every write', sidekiq: :inline do
      submission = send_one
      complete!(submission.submitters.first)

      stub_deletion_cancel

      act_as(admin)
      request_deletion!

      # Signing in still works, through Devise's own door — this is how
      # somebody comes back to cancel, so it is proved with a real POST rather
      # than the test helper's shortcut.
      sign_out(:user)
      reset!

      post '/sign_in', params: { user: { email: admin.email, password: 'correct horse battery' } }

      expect(response).to redirect_to(root_path)

      get '/templates'

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).at('[data-account-deletion-banner]')).to be_present

      get "/submissions/#{submission.id}/download"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.first).to include('sample-document.pdf')

      get "/templates/#{template.id}/submissions_export.csv"

      expect(response).to have_http_status(:ok)

      expect { post '/templates', params: { template: { name: 'While pending deletion' } } }
        .not_to change(Template, :count)
    end

    it 'restores the account when somebody changes their mind', sidekiq: :inline do
      stub_deletion_cancel

      act_as(admin)
      request_deletion!

      post '/settings/account/cancel_deletion'

      expect(response).to redirect_to(settings_account_path)
      expect(account.reload.deletion_requested_at).to be_nil
      expect(account.purge_scheduled_for).to be_nil
      expect(account.suspended_at).to be_nil
      expect(account.suspension_reason).to be_nil

      expect(deliveries.map(&:subject)).to include('Your EsignCenter account will not be deleted')

      act_as(admin)

      expect { post '/templates', params: { template: { name: 'After changing my mind' } } }
        .to change(Template, :count).by(1)
    end
  end

  describe 'the purge at the end of the window' do
    let!(:webhook) { create(:webhook_url, account:) }

    # A row in EVERY table Accounts::Purge::INVENTORY names, so the walk is
    # exercised rather than described (review batch 2, K5). A table that is
    # empty in the fixture proves nothing about the line that empties it — and
    # two of the tables here (the Doorkeeper pair) had no line at all until a
    # reviewer noticed that their foreign keys RESTRICT.
    #
    # The ids everything is counted by are captured HERE, before anything is
    # destroyed: after the purge there are no submitters to ask for their own
    # ids.
    def populate!
      submission = send_one
      complete!(submission.submitters.first)
      submitter = submission.submitters.first

      member = create(:user, account:, role: User::EDITOR_ROLE)
      child = Accounts.find_or_create_testing_user(account).account

      populate_documents!(submitter)
      populate_templates!(member)
      populate_projections!(member)
      populate_account_rows!(member)
      populate_user_rows!(member)

      family_ids = [account.id, child.id]
      template_ids = Template.where(account_id: family_ids).ids

      { submission:, child:, family_ids:, template_ids:,
        user_ids: User.where(account_id: family_ids).ids,
        submitter_ids: Submitter.where(account_id: family_ids).ids,
        webhook_event_ids: WebhookEvent.where(account_id: family_ids).ids,
        attachment_ids: ActiveStorage::Attachment.where(record_type: 'Template', record_id: template_ids).ids }
    end

    def populate_documents!(submitter)
      DocumentGenerationEvent.create!(submitter:, event_name: 'start')
      SubmitterVersion.create!(submitter:, slug: SecureRandom.base58(14), email: submitter.email)
    end

    def populate_templates!(member)
      TemplateSharing.create!(template:, account_id: account.id, ability: 'manage')
      create(:template_access, template:, user: member)
      TemplateVersion.create!(template:, account:, author: admin, data: template.fields.to_json,
                              sha1: Digest::SHA1.hexdigest('v1'))

      document = DynamicDocument.create!(template:, body: '<p>hi</p>', uuid: SecureRandom.uuid,
                                         sha1: Digest::SHA1.hexdigest('body'))
      DynamicDocumentVersion.create!(dynamic_document: document, sha1: Digest::SHA1.hexdigest('v1'))
    end

    def populate_projections!(member)
      create(:email_event, account:, emailable: member)
      EmailMessage.create!(account:, author: admin, subject: 'Hello', body: 'Body',
                           uuid: SecureRandom.uuid, sha1: Digest::SHA1.hexdigest('body'))
      SearchEntry.create!(account:, record: template, tsvector: template.name.to_s, ngram: template.name.to_s)
      DocumentMetadata.create!(account:, blob_checksum: Digest::MD5.base64digest('doc'), text_runs: '[]')

      event = WebhookEvent.create!(account:, webhook_url: webhook, uuid: SecureRandom.uuid,
                                   event_type: 'form.completed', record_type: 'Submitter',
                                   record_id: Submitter.where(account_id: account.id).first&.id,
                                   status: 'error')
      WebhookAttempt.create!(webhook_event: event, attempt: 1, response_status_code: 500)
    end

    def populate_account_rows!(_member)
      AbuseFlag.create!(account:, kind: 'complaint', details: {}, period: '')
      AccountCounters.increment!(account.id, 'anything')
      AccountLimitOverride.create!(account:, note: 'generous')
      AccountAccess.create!(account:, user: admin)
      create(:account_invite, account:)
      AccountMove.create!(from_account: create(:account), to_account: account, user: admin)
      create(:encrypted_config, account:, key: EncryptedConfig::ESIGN_CERTS_KEY, value: { 'cert' => 'x' })
      create(:account_config, account:, key: AccountConfig::ALLOW_TO_DECLINE_KEY, value: true)
      ProvisioningEvent.create!(account:, email: admin.email)
    end

    def populate_user_rows!(member)
      admin.access_token
      admin.mcp_tokens.create!(name: 'Robot')
      create(:user_config, user: member, key: 'test', value: '1')
      EncryptedUserConfig.create!(user: member, key: UserConfig::SIGNATURE_KEY, value: 'x')

      # The two tables whose foreign keys restrict on `users` (K7). The
      # Doorkeeper gem is not in this app, so the rows go in the same way the
      # purge takes them out — through a relation on the bare table.
      # `scopes` is NOT NULL and ApplicationRecord runs strip_attributes, which
      # turns an empty string into nil — so these carry a real scope.
      application = oauth_applications.create!(name: 'Partner', uid: SecureRandom.hex, scopes: 'read',
                                               secret: SecureRandom.hex, redirect_uri: 'https://example.com/cb')
      Accounts::Purge::OauthAccessGrant.create!(application_id: application.id, resource_owner_id: admin.id,
                                                token: SecureRandom.hex, expires_in: 600,
                                                redirect_uri: 'https://example.com/cb', scopes: 'read')
      Accounts::Purge::OauthAccessToken.create!(application_id: application.id, resource_owner_id: admin.id,
                                                token: SecureRandom.hex, scopes: 'read',
                                                previous_refresh_token: 'none')
    end

    def oauth_applications
      Class.new(ApplicationRecord) { self.table_name = 'oauth_applications' }
    end

    # Driven off Purge::INVENTORY itself: a table added to that constant with
    # no counter here raises KeyError naming the table, which is the point —
    # the inventory and its proof cannot drift apart.
    def remaining_rows(fixture)
      counters = row_counters(fixture)

      Accounts::Purge::INVENTORY.index_with { |table| counters.fetch(table).call }
    end

    def row_counters(fixture)
      accounts = fixture[:family_ids]
      submitters = fixture[:submitter_ids]
      templates = fixture[:template_ids]
      users = fixture[:user_ids]

      by_account = ->(model) { -> { model.where(account_id: accounts).count } }
      by_submitter = ->(model) { -> { model.where(submitter_id: submitters).count } }
      by_template = ->(model) { -> { model.where(template_id: templates).count } }
      by_user = ->(model, column = :user_id) { -> { model.where(column => users).count } }
      dynamic_document_ids = -> { DynamicDocument.where(template_id: templates).select(:id) }

      { 'active_storage_attachments' => lambda {
        ActiveStorage::Attachment.where(id: fixture[:attachment_ids]).count
      },
        'completed_documents' => by_submitter.call(CompletedDocument),
        'document_generation_events' => by_submitter.call(DocumentGenerationEvent),
        'submitter_versions' => by_submitter.call(SubmitterVersion),
        'completed_submitters' => by_account.call(CompletedSubmitter),
        'submission_events' => by_account.call(SubmissionEvent),
        'submitters' => by_account.call(Submitter),
        'submissions' => by_account.call(Submission),
        'dynamic_document_versions' => lambda {
          DynamicDocumentVersion.where(dynamic_document_id: dynamic_document_ids.call).count
        },
        'dynamic_documents' => by_template.call(DynamicDocument),
        'template_sharings' => by_template.call(TemplateSharing),
        'template_accesses' => by_template.call(TemplateAccess),
        'template_versions' => by_account.call(TemplateVersion),
        'templates' => by_account.call(Template),
        'template_folders' => by_account.call(TemplateFolder),
        'document_metadata' => by_account.call(DocumentMetadata),
        'email_events' => by_account.call(EmailEvent),
        'email_messages' => by_account.call(EmailMessage),
        'search_entries' => by_account.call(SearchEntry),
        'webhook_attempts' => lambda {
          WebhookAttempt.where(webhook_event_id: fixture[:webhook_event_ids]).count
        },
        'webhook_events' => by_account.call(WebhookEvent),
        'webhook_urls' => by_account.call(WebhookUrl),
        'abuse_flags' => by_account.call(AbuseFlag),
        'account_counters' => by_account.call(AccountCounter),
        'account_limit_overrides' => by_account.call(AccountLimitOverride),
        'account_accesses' => by_account.call(AccountAccess),
        'account_invites' => by_account.call(AccountInvite),
        'account_linked_accounts' => lambda {
          AccountLinkedAccount.where(account_id: accounts)
                              .or(AccountLinkedAccount.where(linked_account_id: accounts)).count
        },
        'account_moves' => lambda {
          AccountMove.where(from_account_id: accounts)
                     .or(AccountMove.where(to_account_id: accounts)).count
        },
        'encrypted_configs' => by_account.call(EncryptedConfig),
        'account_configs' => by_account.call(AccountConfig),
        'provisioning_events' => by_account.call(ProvisioningEvent),
        'access_tokens' => by_user.call(AccessToken),
        'mcp_tokens' => by_user.call(McpToken),
        'user_configs' => by_user.call(UserConfig),
        'encrypted_user_configs' => by_user.call(EncryptedUserConfig),
        'oauth_access_grants' => by_user.call(Accounts::Purge::OauthAccessGrant, :resource_owner_id),
        'oauth_access_tokens' => by_user.call(Accounts::Purge::OauthAccessToken, :resource_owner_id),
        'users' => -> { User.where(account_id: accounts).count } }
    end

    it 'destroys every table of the inventory, releases the email, keeps the /verify record and leaves ' \
       'a tombstone', sidekiq: :inline do
      fixture = populate!
      admin_email = admin.email
      blob_ids = ActiveStorage::Attachment.where(id: fixture[:attachment_ids]).pluck(:blob_id)
      verified = VerifiedDocument.where(submission_id: fixture[:submission].id).to_a

      # The fixture has to be REAL, or the walk proves nothing: every table
      # named in the inventory carries at least one row before we start.
      expect(remaining_rows(fixture).select { |_, count| count.zero? }).to eq({})
      expect(blob_ids).not_to be_empty
      expect(verified).not_to be_empty

      account.update!(deletion_requested_at: 90.days.ago, purge_scheduled_for: 1.minute.ago)

      expect(Accounts::Purge.call(account)).to eq(:purged)

      remaining = remaining_rows(fixture)

      expect(remaining).to eq(remaining.transform_values { 0 })

      # The files, not only the rows.
      expect(ActiveStorage::Blob.where(id: blob_ids).count).to eq(0)
      expect(ActiveStorage::Attachment.where(blob_id: blob_ids).count).to eq(0)

      # Nothing left pointing at the account in the four tables the database
      # itself would not have complained about.
      expect(Accounts::Purge.orphans(account.id).values).to all(eq(0))

      # The address can be registered again.
      expect(User.exists?(email: admin_email)).to be(false)

      # /verify keeps working forever — the record names nobody.
      verified.each do |record|
        expect(VerifiedDocument.find_by(id: record.id)).to have_attributes(
          sha256: record.sha256, signers_count: record.signers_count, signed_at: record.signed_at
        )
      end

      # The tombstone — the parent's, and the testing child's (K2): deleting
      # the child row outright would leave verified_documents.account_id
      # pointing at nothing.
      expect(account.reload).to have_attributes(name: Accounts::Purge::TOMBSTONE_NAME, purged_at: be_present,
                                                archived_at: be_present, uuid: be_present)
      # The claim has served its purpose, and a tombstone must not still carry
      # a credential's digest (review batch 2, R7).
      expect(account).to have_attributes(purge_started_at: nil, deletion_code_digest: nil,
                                         deletion_code_expires_at: nil, deletion_code_attempts: 0,
                                         deletion_code_user_id: nil, deletion_code_window_started_at: nil)
      expect(fixture[:child].reload).to have_attributes(name: Accounts::Purge::TOMBSTONE_NAME,
                                                        purged_at: be_present)

      # And running it again is a no-op.
      expect(Accounts::Purge.call(account)).to eq(:already_purged)
    end

    it 'keeps the money history and unnames the Stripe audit rather than deleting it' do
      subscription = create(:account_subscription, account:, access_state: 'cancelled', status: 'canceled',
                                                   stripe_subscription_id: 'sub_gone')
      inbox = StripeEventInbox.create!(account_id: account.id, stripe_event_id: "evt_#{SecureRandom.hex(6)}",
                                       event_type: 'customer.subscription.deleted',
                                       payload: '{"id":"evt"}', status: 'processed')

      Accounts::Purge.call(account)

      expect(subscription.reload.stripe_subscription_id).to eq('sub_gone')
      expect(inbox.reload.account_id).to be_nil
    end

    it 'refuses an internal account and an account that is still being charged' do
      template
      internal = create(:account, :internal)

      expect { Accounts::Purge.call(internal) }.to raise_error(Accounts::Purge::Refused, /not a customer/)
      expect(internal.reload.purged_at).to be_nil

      create(:account_subscription, account:, access_state: 'active')

      expect { Accounts::Purge.call(account) }.to raise_error(Accounts::Purge::Refused, /live paid subscription/)
      expect(account.reload.purged_at).to be_nil
      # And nothing was half-destroyed on the way to the refusal.
      expect(Template.where(account_id: account.id).count).to eq(1)
      expect(User.where(account_id: account.id).count).to eq(1)
    end

    # A testing child rode in on its parent's decision and was checked for
    # nothing at all (review batch 2, K2). Three ways that goes wrong, and all
    # three now stop the WHOLE purge — the parent included — because half a
    # family emptied is the state nobody can reason about afterwards.
    describe 'a testing child that fails its own checks' do
      let(:child) { Accounts.find_or_create_testing_user(account).account }

      before { template }

      it 'refuses when the link points at an account that is not a customer' do
        child.update!(account_kind: Account::INTERNAL_KIND)

        expect { Accounts::Purge.call(account) }
          .to raise_error(Accounts::Purge::Refused, /testing child #{child.id} is a internal account/)

        expect(account.reload.purged_at).to be_nil
        expect(child.reload.purged_at).to be_nil
        expect(Template.where(account_id: account.id).count).to eq(1)
      end

      it 'refuses when the child is linked to more than this one parent' do
        AccountLinkedAccount.create!(account: create(:account), linked_account: child, account_type: :testing)

        expect { Accounts::Purge.call(account) }
          .to raise_error(Accounts::Purge::Refused, /not linked to it as a testing account alone/)

        expect(account.reload.purged_at).to be_nil
        expect(User.where(account_id: child.id).count).to eq(1)
      end

      it 'refuses when the child still holds a live paid subscription of its own' do
        create(:account_subscription, account: child, access_state: 'active')

        expect { Accounts::Purge.call(account) }
          .to raise_error(Accounts::Purge::Refused, /testing child #{child.id} still holds a live paid subscription/)

        expect(account.reload.purged_at).to be_nil
        expect(Template.where(account_id: account.id).count).to eq(1)
      end
    end

    # Cloning a template reuses the blob rather than re-uploading it
    # (lib/templates/clone_attachments.rb), and a template can be cloned into
    # another account — so one file really can be two accounts' document.
    # Destroying it with the first account would have broken the second one's
    # copy, with no way back (review batch 2, K3).
    it 'leaves a file another account is also attached to, and tells the operator', sidekiq: :inline do
      other_account = create(:account)
      other_admin = create(:user, account: other_account)
      other_template = create(:template, account: other_account, author: other_admin, only_field_types: %w[text])

      shared_blob = template.documents_attachments.first.blob
      shared = ActiveStorage::Attachment.create!(blob: shared_blob, name: :documents, record: other_template)

      allow(OperatorAlert).to receive(:deliver).and_call_original

      Accounts::Purge.call(account)

      expect(ActiveStorage::Blob.exists?(shared_blob.id)).to be(true)
      expect(shared.reload.blob.service.exist?(shared_blob.key)).to be(true)
      expect(ActiveStorage::Attachment.where(record: template).count).to eq(0)
      expect(OperatorAlert).to have_received(:deliver)
        .with(hash_including(subject: 'Account purge kept shared files'))
    end

    # Cloning a template into YOUR OWN account reuses the blob in exactly the
    # same way — and that file is shared with nobody, so the purge has to take
    # it. One attachment at a time it could not: the first row's blob delete
    # tripped the foreign key of the second, the row transaction rolled back,
    # and the FILE had already gone. Every retry hit the same violation, so the
    # account stayed claimed and archived for ever (review 7, P2).
    it 'purges a template and the clone of it that shares the same file', sidekiq: :inline do
      act_as(admin)

      post "/templates/#{template.id}/clone", params: { template: { name: 'A copy' } }

      clone = Template.where(account_id: account.id).where.not(id: template.id).sole
      shared_blob = template.documents_attachments.first.blob

      expect(clone.documents_attachments.first.blob_id).to eq(shared_blob.id)
      expect(ActiveStorage::Attachment.where(blob_id: shared_blob.id).count).to eq(2)

      expect(Accounts::Purge.call(account)).to eq(:purged)

      # Rows, blob row and the object — and no exception on the way.
      expect(ActiveStorage::Attachment.where(blob_id: shared_blob.id).count).to eq(0)
      expect(ActiveStorage::Blob.where(id: shared_blob.id).count).to eq(0)
      expect(shared_blob.service.exist?(shared_blob.key)).to be(false)
      expect(Template.where(account_id: account.id).count).to eq(0)
    end

    # Every page image of every document uploaded to this app is an attachment
    # hanging off ANOTHER attachment: config/initializers/active_storage.rb
    # declares `has_many_attached :preview_images` on
    # ActiveStorage::Attachment, so a preview's `record_type` is
    # 'ActiveStorage::Attachment' — a type the walk never named. Rows, blob
    # rows and the PNGs themselves survived every purge, and the completeness
    # check could not notice because it asked the walk's own question (review
    # 7, P1).
    it 'destroys the page images that hang off the documents, files included', sidekiq: :inline do
      submission = send_one
      complete!(submission.submitters.first)

      parents = [template.documents_attachments.first,
                 submission.submitters.first.reload.documents_attachments.first,
                 submission.reload.audit_trail_attachment]

      expect(parents).to all(be_present)

      previews = parents.map do |parent|
        parent.preview_images.attach(io: StringIO.new('PNG-BYTES-OF-A-CUSTOMER-DOCUMENT-PAGE'),
                                     filename: '0.png', content_type: 'image/png')

        parent.reload.preview_images_attachments.first
      end

      blobs = previews.map(&:blob)

      expect(previews.map(&:record_type)).to all(eq('ActiveStorage::Attachment'))
      expect(blobs.map { |blob| blob.service.exist?(blob.key) }).to all(be(true))

      expect(Accounts::Purge.call(account)).to eq(:purged)

      expect(ActiveStorage::Attachment.where(id: previews.map(&:id)).count).to eq(0)
      expect(ActiveStorage::Blob.where(id: blobs.map(&:id)).count).to eq(0)
      expect(blobs.map { |blob| blob.service.exist?(blob.key) }).to all(be(false))
    end

    # And the completeness check no longer shares the walk's blind spots. With
    # the resolver deliberately blinded to one record type — which is exactly
    # what the preview bug was — the count is taken from the RECORD ids
    # captured before the walk, so the purge refuses rather than stamping a
    # tombstone over what it left behind (review 7, P1).
    it 'refuses to entomb an account whose walk missed a whole record type', sidekiq: :inline do
      submission = send_one
      complete!(submission.submitters.first)

      expect(ActiveStorage::Attachment.where(record_type: 'Submitter').count).to be_positive

      allow(Accounts::Purge).to receive(:attachments_for).and_wrap_original do |original, *args|
        original.call(*args).where.not(record_type: 'Submitter')
      end
      allow(OperatorAlert).to receive(:deliver).and_call_original

      expect { Accounts::Purge.call(account) }
        .to raise_error(Accounts::Purge::Refused, /active_storage_attachments=/)

      expect(account.reload.purged_at).to be_nil
      expect(OperatorAlert).to have_received(:deliver)
        .with(hash_including(subject: 'Account purge did not empty the account'))
    end

    # A file that will not delete used to be swallowed: the attachment row was
    # deleted, the file stayed in the bucket, and `purged_at` was stamped over
    # it — the account read as destroyed while the customer's documents were
    # still there (review batch 2, K4).
    # ActiveStorage's own `Blob#purge` destroys the DATABASE ROWS FIRST and
    # only then deletes the object, so a storage failure orphans the file with
    # no locator left anywhere (review batch 2, P7). We do it the other way
    # round: object, variants, verify, then rows. A failure therefore leaves
    # BOTH rows in place — which is what lets the retry find the file again.
    it 'leaves the attachment and blob rows in place when the object will not delete, and finishes on the ' \
       'next run', sidekiq: :inline do
      service = ActiveStorage::Blob.service
      attachment_ids = ActiveStorage::Attachment.where(record: template).ids
      blob_ids = ActiveStorage::Attachment.where(id: attachment_ids).pluck(:blob_id)

      expect(blob_ids).not_to be_empty

      allow(service).to receive(:delete).and_raise(Errno::EACCES)
      allow(OperatorAlert).to receive(:deliver).and_call_original

      expect { Accounts::Purge.call(account) }.to raise_error(Accounts::Purge::StorageFailure)

      # Both rows survive, so the retry still knows which file it was.
      expect(ActiveStorage::Attachment.where(id: attachment_ids).count).to eq(attachment_ids.size)
      expect(ActiveStorage::Blob.where(id: blob_ids).count).to eq(blob_ids.size)

      # No tombstone over a bucket that still holds their documents, and the
      # walk stopped where it stood: files come first, so nothing else has
      # been deleted either.
      expect(account.reload.purged_at).to be_nil
      expect(Template.where(account_id: account.id).count).to eq(1)
      expect(User.where(account_id: account.id).count).to eq(1)
      expect(OperatorAlert).to have_received(:deliver)
        .with(hash_including(subject: 'Account purge could not delete a file'))

      # Storage comes back, and the second run finishes the job.
      allow(service).to receive(:delete).and_call_original

      expect(Accounts::Purge.call(account.reload)).to eq(:purged)
      expect(ActiveStorage::Blob.where(id: blob_ids).count).to eq(0)
      expect(account.reload.purged_at).to be_present
    end

    # The variants and previews are as much the customer's document as the
    # original: a preview image of a signed contract is still their contract
    # (P7).
    it 'deletes the blob variants and previews alongside the object', sidekiq: :inline do
      service = ActiveStorage::Blob.service
      keys = ActiveStorage::Attachment.where(record: template).map { |a| a.blob.key }

      allow(service).to receive(:delete_prefixed).and_call_original

      Accounts::Purge.call(account)

      keys.each do |key|
        expect(service).to have_received(:delete_prefixed).with("variants/#{key}/")
      end
    end

    # The whole 90 days, walked: request, wait, and the nightly sweep does the
    # rest without anybody asking it to.
    it 'is what the nightly sweep does once the date passes', sidekiq: :inline do
      populate!

      act_as(admin)
      request_deletion!

      expect(Accounts::Retention.purge_candidates).to be_empty

      travel_to((Accounts::Deletion::WINDOW_DAYS + 1).days.from_now) do
        expect(Accounts::Retention.purge_candidates.map(&:id)).to include(account.id)

        perform_enqueued_jobs(only: AccountPurgeJob) { Accounts::Retention.purge_due! }
      end

      expect(account.reload.purged_at).to be_present
      expect(Template.where(account_id: account.id).count).to eq(0)
    end

    # The claim (review batch 2, P1). Once the job has stamped
    # `purge_started_at` the account is committed: the purge is running outside
    # any lock a request could wait on, so cancelling has nothing whole to come
    # back to and must be refused rather than quietly ignored.
    it 'refuses to cancel a deletion once the purge has claimed the account', sidekiq: :inline do
      template
      act_as(admin)
      request_deletion!

      account.update!(purge_started_at: Time.current)

      expect(Accounts::Deletion.cancel!(account.reload)).to be(false)
      expect(account.reload.deletion_requested_at).to be_present
      expect(deliveries.map(&:subject)).not_to include('Your EsignCenter account will not be deleted')

      # And the door is not merely refused, it is CLOSED: the claim also stops
      # sign-in, so the session that was open a moment ago no longer resolves
      # to a user and the request never reaches the action.
      post '/settings/account/cancel_deletion'

      expect(response).to redirect_to(new_user_session_path)
      expect(account.reload.purge_scheduled_for).to be_present
    end

    # The narrow case the sign-in guard cannot cover: the claim landing after
    # this request authenticated. The controller branches on cancel!'s answer,
    # and says what happened rather than reporting a success (P1).
    it 'says the deletion has already started rather than claiming it was cancelled' do
      act_as(admin)
      request_deletion!

      allow(Accounts::Deletion).to receive(:cancel!).and_return(false)

      post '/settings/account/cancel_deletion'

      expect(flash[:alert]).to eq(I18n.t('account_deletion_already_started'))
      expect(flash[:notice]).not_to eq(I18n.t('account_deletion_cancelled_notice'))
      expect(account.reload.purge_scheduled_for).to be_present
    end

    # Sign-in is the other thing the account lock cannot see, because it does
    # not take one. After the claim it stops (P1).
    it 'refuses sign-in once the purge has claimed the account' do
      admin
      account.update!(purge_started_at: Time.current)

      sign_out(:user)
      reset!

      post '/sign_in', params: { user: { email: admin.email, password: 'correct horse battery' } }

      expect(response).not_to redirect_to(root_path)
      expect(admin.reload.active_for_authentication?).to be(false)
    end

    # A failed purge leaves the claim set, so the retry RESUMES rather than
    # re-deciding — a half-emptied account no longer looks eligible, and
    # re-deciding would leave it half-emptied for ever (P1).
    it 'keeps the claim through a failure so the retry finishes the job', sidekiq: :inline do
      service = ActiveStorage::Blob.service

      template
      act_as(admin)
      request_deletion!

      travel_to((Accounts::Deletion::WINDOW_DAYS + 1).days.from_now) do
        allow(service).to receive(:delete).and_raise(Errno::EACCES)

        expect { AccountPurgeJob.new.perform(account.id) }.to raise_error(Accounts::Purge::StorageFailure)

        expect(account.reload.purge_started_at).to be_present
        expect(account.purged_at).to be_nil

        allow(service).to receive(:delete).and_call_original

        AccountPurgeJob.new.perform(account.id)
      end

      expect(account.reload.purged_at).to be_present
      expect(Template.where(account_id: account.id).count).to eq(0)
    end

    # And the claim is only granted once: a Stripe webhook that puts the
    # account back on a paid plan between the claim and the purge is caught by
    # the purge's own refusal, which it re-asserts on entry (P1).
    it 'still refuses a purge whose account went back onto a paid plan after the claim', sidekiq: :inline do
      template
      account.update!(purge_started_at: Time.current, deletion_requested_at: 90.days.ago,
                      purge_scheduled_for: 1.minute.ago)
      create(:account_subscription, account:, access_state: 'active')

      AccountPurgeJob.new.perform(account.id)

      expect(account.reload.purged_at).to be_nil
      expect(Template.where(account_id: account.id).count).to eq(1)
    end

    # A claim that is never released is worse than the race it prevents
    # (review batch 2, R1): every user is locked out of an account nobody is
    # actually deleting, and cancel! refuses because it sees the claim.
    it 'releases the claim when the purge is refused, and the account works again', sidekiq: :inline do
      template
      act_as(admin)
      request_deletion!

      travel_to((Accounts::Deletion::WINDOW_DAYS + 1).days.from_now) do
        # Stripe says the account is paying again, between the claim and the
        # purge — so the purge refuses.
        create(:account_subscription, account:, access_state: 'active')

        AccountPurgeJob.new.perform(account.id)
      end

      account.reload

      expect(account.purge_started_at).to be_nil
      expect(account.purged_at).to be_nil
      expect(account.archived_at).to be_nil
      expect(Template.where(account_id: account.id).count).to eq(1)

      # Sign-in works again, and so does calling the deletion off.
      expect(admin.reload.active_for_authentication?).to be(true)
      expect(Accounts::Deletion.cancel!(account)).to be(true)
      expect(account.reload.deletion_requested_at).to be_nil
    end

    # And when the storage problem is permanent, the claim is released on the
    # way out and a person is paged rather than the account being left frozen
    # and half-emptied in silence (R1).
    it 'releases the claim and pages the operator when the retries are exhausted', sidekiq: :inline do
      template
      account.update!(deletion_requested_at: 90.days.ago, purge_scheduled_for: 1.minute.ago)

      allow(OperatorAlert).to receive(:deliver).and_call_original

      Accounts::Purge.claim!(account)

      expect(account.reload.purge_started_at).to be_present

      # Driven through ActiveJob's own dispatch, with the attempt budget
      # already spent — which is exactly the state the last retry is in.
      job = AccountPurgeJob.new(account.id)

      # ActiveJob counts a retry budget per RESCUE LIST, and that list is the
      # key — `[Accounts::Purge::StorageFailure]`, brackets included — not the
      # bare class name. Spending it here puts the job in exactly the state
      # the final attempt is in, so the block under `retry_on` runs instead of
      # a sixth retry.
      job.exception_executions = { '[Accounts::Purge::StorageFailure]' => AccountPurgeJob::MAX_STORAGE_ATTEMPTS }
      job.rescue_with_handler(Accounts::Purge::StorageFailure.new('bucket is unreachable'))

      expect(account.reload.purge_started_at).to be_nil
      expect(account.archived_at).to be_nil
      expect(admin.reload.active_for_authentication?).to be(true)
      expect(OperatorAlert).to have_received(:deliver).with(hash_including(subject: 'Account purge gave up'))
    end

    # A failure that is neither a refusal nor a storage problem — a foreign
    # key, a deadlock, a bug — had no ending at all: after the retries the
    # account was still claimed and archived, every user locked out, `cancel!`
    # refusing, and nobody paged, because the "gave up" alert only fired for
    # storage (review 7, P2).
    it 'releases the claim and pages the operator when the purge fails for any other reason', sidekiq: :inline do
      template
      account.update!(deletion_requested_at: 90.days.ago, purge_scheduled_for: 1.minute.ago)

      allow(OperatorAlert).to receive(:deliver).and_call_original

      Accounts::Purge.claim!(account)

      expect(account.reload.purge_started_at).to be_present

      # Same technique as the example above: the retry budget for THIS rescue
      # list — `[StandardError]`, brackets included — is already spent, which
      # is the state the last attempt is in, so the block under `retry_on`
      # runs instead of a sixth retry.
      job = AccountPurgeJob.new(account.id)

      job.exception_executions = { '[StandardError]' => AccountPurgeJob::MAX_ATTEMPTS }
      job.rescue_with_handler(ActiveRecord::InvalidForeignKey.new('violates foreign key constraint'))

      expect(account.reload.purge_started_at).to be_nil
      expect(account.archived_at).to be_nil
      expect(admin.reload.active_for_authentication?).to be(true)
      expect(OperatorAlert).to have_received(:deliver).with(hash_including(subject: 'Account purge failed'))
    end

    # The claim is a BARRIER, not a note (review batch 2, R2b): a signer
    # part-way through a document cannot complete it into an account whose
    # rows are being deleted, and nothing new can be created either.
    it 'refuses signer writes and new documents once the purge has claimed the account', sidekiq: :inline do
      submission = send_one
      submitter = submission.submitters.first

      Accounts::Purge.claim!(account)

      sign_out(:user)
      reset!

      put "/s/#{submitter.slug}", params: { completed: 'true', esign_consent: 'true',
                                            esign_consent_version: EsignConsent::VERSION,
                                            values: { text_field(submitter)['uuid'] => 'Jane' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => I18n.t('form_has_been_archived'))
      expect(submitter.reload.completed_at).to be_nil

      post "/s/#{submitter.slug}/decline", params: { reason: 'No thanks' }

      expect(submitter.reload.declined_at).to be_nil

      # And the chokepoint every creation path shares refuses too.
      expect { Quotas.assert_can_create_submissions!(account.reload) }
        .to raise_error(Quotas::LimitReached) { |e| expect(e.reason).to eq(:suspended) }
    end

    # A webhook landing between the claim and the purge must not hand paid
    # access back to a half-emptied account (R2a).
    it 'never grants paid access to a claimed account, and tells a person about the money', sidekiq: :inline do
      row = create(:account_subscription, account:, access_state: 'cancelled', status: 'canceled',
                                          stripe_subscription_id: 'sub_live')

      Accounts::Purge.claim!(account)

      allow(OperatorAlert).to receive(:deliver).and_call_original

      StripeBilling::SubscriptionSync.apply!(row, JSON.parse(fixture_body('subscription-active')))

      expect(row.reload.access_state).to eq('cancelled')
      expect(Plans.key_for(account.reload)).to eq(Plans::FREE)
      # The facts are still recorded — this is the money history.
      expect(row.stripe_status).to eq('active')
      expect(OperatorAlert).to have_received(:deliver)
        .with(hash_including(subject: 'Stripe subscription applied to an account being purged'))
    end

    # The walk works from ids collected at its start, so anything that lands
    # DURING it would otherwise survive under a tombstone that says the
    # account was emptied (R2d).
    it 'takes stragglers that appear during the walk, and refuses to entomb a non-empty account',
       sidekiq: :inline do
      submission = send_one
      straggler = nil

      allow(Accounts::Purge).to receive(:delete_users!).and_wrap_original do |method, record|
        # One more row arrives just as the walk reaches the end of it — the
        # shape of a webhook or a background job landing mid-purge.
        straggler ||= AccountCounters.increment!(record.id, 'arrived-during-the-purge')

        method.call(record)
      end

      expect(Accounts::Purge.call(account)).to eq(:purged)

      expect(straggler).to eq(1)
      expect(AccountCounter.where(account_id: account.id).count).to eq(0)
      expect(Submission.where(id: submission.id).count).to eq(0)
    end

    # The three locator rows go together, or none of them do (R4).
    it 'deletes the blob variant records with the attachment and the blob', sidekiq: :inline do
      attachment = ActiveStorage::Attachment.where(record: template).first
      blob = attachment.blob
      variant = ActiveStorage::VariantRecord.create!(blob_id: blob.id, variation_digest: SecureRandom.hex(8))

      Accounts::Purge.call(account)

      expect(ActiveStorage::VariantRecord.where(id: variant.id).count).to eq(0)
      expect(ActiveStorage::Attachment.where(id: attachment.id).count).to eq(0)
      expect(ActiveStorage::Blob.where(id: blob.id).count).to eq(0)
    end

    # The operator's two doors do exactly what the job does (review batch 2,
    # R3): `purge` claims the barrier first and releases it on a refusal, and
    # `cancel_deletion` refuses out loud rather than printing success over an
    # account that is already being emptied.
    describe 'the operator rake tasks' do
      def run_task(name, id)
        task = Rake::Task["accounts:#{name}"]

        task.reenable
        capture_stdout { task.invoke(id) }
      end

      before { Rails.application.load_tasks unless Rake::Task.task_defined?('accounts:purge') }

      it 'refuses to cancel a deletion the purge has already claimed, and says why' do
        template
        act_as(admin)
        request_deletion!

        Accounts::Purge.claim!(account)

        expect { run_task('cancel_deletion', account.id) }.to raise_error(SystemExit)
        expect(account.reload.deletion_requested_at).to be_present
      end

      it 'releases the claim it took when the purge refuses' do
        template
        create(:account_subscription, account:, access_state: 'active')

        expect { run_task('purge', account.id) }.to raise_error(SystemExit)

        account.reload

        expect(account.purge_started_at).to be_nil
        expect(account.archived_at).to be_nil
        expect(account.purged_at).to be_nil
        expect(Template.where(account_id: account.id).count).to eq(1)
      end

      it 'lets an operator release a claim by hand' do
        template
        Accounts::Purge.claim!(account)

        output = run_task('release_purge_claim', account.id)

        expect(output).to include('Released the purge claim')
        expect(account.reload.purge_started_at).to be_nil
        expect(account.archived_at).to be_nil
        expect(admin.reload.active_for_authentication?).to be(true)
      end
    end

    # The sweep decided minutes ago; the job acts now. In between somebody may
    # have changed their mind, and acting on the stale decision is the one
    # mistake here that cannot be undone (review batch 2, K1).
    it 'does not purge an account whose deletion was cancelled between the sweep and the job',
       sidekiq: :inline do
      template
      act_as(admin)
      request_deletion!

      travel_to((Accounts::Deletion::WINDOW_DAYS + 1).days.from_now) do
        # The sweep would enqueue it: at this moment the account really is due.
        expect(Accounts::Retention.purge_candidates.map(&:id)).to include(account.id)

        # Somebody presses "Cancel deletion" while the job is still queued...
        Accounts::Deletion.cancel!(account.reload)

        # ...and the job runs anyway, on the decision the sweep made.
        AccountPurgeJob.new.perform(account.id)
      end

      expect(account.reload.purged_at).to be_nil
      expect(Template.where(account_id: account.id).count).to eq(1)
      expect(User.where(account_id: account.id).count).to eq(1)
    end
  end
end

# Accounts nobody uses (D43): a year of silence, three warnings, then the same
# purge.
RSpec.describe 'Accounts nobody signs in to', type: :request do
  let(:account) { create(:account, created_at: 3.years.ago) }
  let!(:owner) { create(:user, account:, created_at: 3.years.ago, current_sign_in_at: 13.months.ago) }
  let(:deliveries) { ActionMailer::Base.deliveries }

  before { deliveries.clear }

  # Nothing dormant is purged until the FINAL warning has been out for a week
  # (review batch 2, K6), so every example that expects a purge has to have
  # sent one — and sends it through the real sweep rather than stamping the
  # columns by hand, or it would be proving the stamp instead of the rule.
  # Scoped to the recipient, never to "every warning in the outbox": these
  # examples travel a year forward, and any other account the suite has left
  # behind would be dormant by then too.
  def warnings_for(user)
    deliveries.select { |m| m.subject.include?('unused EsignCenter account') && m.to == [user.email] }
  end

  def warn_finally!(record = account)
    record.reload
    # An hour PAST the boundary, not exactly on it: a nightly sweep lands
    # somewhere inside the day, and `travel_to` truncates to whole seconds, so
    # sitting exactly on `purge_at - 7 days` puts the deadline a hair in the
    # future and the letter waits for tomorrow.
    moment = Accounts::Retention.dormant_purge_at(record) -
             Accounts::Retention::FINAL_WARNING_DAYS.days + 1.hour

    travel_to(moment) { Accounts::Retention.schedule_dormant_warnings! }

    record.reload
  end

  it 'is a purge candidate after a year of silence, and is not one the day after somebody signs in' do
    warn_finally!

    expect(Accounts::Retention.purge_candidates.map(&:id)).to include(account.id)

    owner.update!(current_sign_in_at: 1.day.ago)

    expect(Accounts::Retention.purge_candidates.map(&:id)).not_to include(account.id)
  end

  # A paid account is never dormant, and a cancelled one is protected for a
  # year after the money stopped — the promise is about the documents, not
  # about how often anybody logs in.
  it 'is never a candidate while it pays, nor within a year of the subscription ending' do
    warn_finally!

    row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                        stripe_subscription_id: 'sub_paid')

    expect(Accounts::Retention.purge_candidates.map(&:id)).not_to include(account.id)

    row.update!(access_state: 'cancelled', status: 'canceled', ended_at: 6.months.ago)

    expect(Accounts::Retention.purge_candidates.map(&:id)).not_to include(account.id)

    row.update!(ended_at: 14.months.ago)

    expect(Accounts::Retention.purge_candidates.map(&:id)).to include(account.id)
  end

  it 'warns at 60, 30 and 7 days, once each, and then purges on the date', sidekiq: :inline do
    # Reset the clock so the purge date is a year away and the warnings are
    # still ahead of us.
    owner.update!(current_sign_in_at: Time.current, last_sign_in_at: Time.current)
    purge_at = Accounts::Retention.dormant_purge_at(account)

    # An hour into each day, the way a nightly sweep actually runs.
    [61, 60, 45, 30, 20, 7, 3].each do |days_before|
      travel_to(purge_at - days_before.days + 1.hour) { Accounts::Retention.schedule_dormant_warnings! }
    end

    warnings = warnings_for(owner)

    expect(warnings.map { |m| m.subject[/in (\d+) days/, 1].to_i }).to eq([60, 30, 7])
    expect(warnings.first.to).to contain_exactly(owner.email)
    expect(warnings.last.body.encoded).to include(Accounts::Deletion.format_date(purge_at))

    # And the final letter left its mark, which is what lets the purge happen
    # at all (K6).
    expect(account.reload.dormant_warning_sent_at).to be_within(1.minute).of(purge_at - 7.days + 1.hour)
    expect(account.dormant_warning_for).to be_within(1.minute).of(purge_at)

    travel_to(purge_at + 2.hours) do
      expect(Accounts::Retention.purge_candidates.map(&:id)).to include(account.id)

      perform_enqueued_jobs(only: AccountPurgeJob) { Accounts::Retention.purge_due! }
    end

    expect(account.reload.purged_at).to be_present
    expect(User.where(account_id: account.id).count).to eq(0)
  end

  # The scenario that made K6 Critical: an account that was ALREADY a year
  # idle the day this feature shipped. Its purge date is in the past, so the
  # old sweep skipped it entirely (`next if purge_at <= now`) and the purge
  # took it on the very first night — with no 60-day letter, no 30-day letter
  # and no 7-day letter. Now it is given a week from the day we notice, told
  # so, and taken a week later.
  it 'warns an account that was already overdue when we first looked, and purges it a week later',
     sidekiq: :inline do
    expect(Accounts::Retention.dormant_purge_at(account)).to be < Time.current
    expect(Accounts::Retention.purge_candidates).to be_empty

    Accounts::Retention.schedule_dormant_warnings!

    warning = warnings_for(owner).first

    expect(warning).to be_present
    expect(warning.subject).to include('in 7 days')
    expect(account.reload.dormant_warning_for).to be_within(1.minute).of(7.days.from_now)

    # Still nothing to purge today, or the day before the deadline.
    expect(Accounts::Retention.purge_candidates).to be_empty

    travel_to(6.days.from_now) do
      Accounts::Retention.schedule_dormant_warnings!

      expect(Accounts::Retention.purge_candidates).to be_empty
      # And the deadline did not slide: one letter, one date.
      expect(warnings_for(owner).size).to eq(1)
    end

    travel_to(7.days.from_now + 1.hour) do
      expect(Accounts::Retention.purge_candidates.map(&:id)).to include(account.id)

      perform_enqueued_jobs(only: AccountPurgeJob) { Accounts::Retention.purge_due! }
    end

    expect(account.reload.purged_at).to be_present
  end

  # The other half of K1: the dormant path. Signing in is how somebody says
  # "I am still here", and it has to count even after the sweep has already
  # decided.
  it 'does not purge a dormant account whose owner signed in between the sweep and the job',
     sidekiq: :inline do
    create(:template, account:, author: owner, only_field_types: %w[text])
    warn_finally!

    expect(Accounts::Retention.purge_candidates.map(&:id)).to include(account.id)

    owner.update!(current_sign_in_at: Time.current)

    AccountPurgeJob.new.perform(account.id)

    expect(account.reload.purged_at).to be_nil
    expect(Template.where(account_id: account.id).count).to eq(1)
    expect(User.where(account_id: account.id).count).to eq(1)
  end

  # The dedupe counter is claimed before the mail is enqueued, so two sweeps
  # cannot both send — but it is GIVEN BACK when the enqueue fails (review
  # batch 2, K10). Without that, one Redis wobble spent the key for ever and
  # the customer was never warned at all, which for the 7-day letter is the
  # difference between a deletion they saw coming and one they did not.
  it 'gives the warning key back when the mail cannot be sent, and sends it on the next sweep' do
    delivery = instance_double(ActionMailer::MessageDelivery)

    allow(AccountMailer).to receive(:dormant_warning).and_return(delivery)
    allow(delivery).to receive(:deliver_now!).and_raise(RuntimeError, 'the mail server is down')

    Accounts::Retention.schedule_dormant_warnings!

    expect(delivery).to have_received(:deliver_now!).once
    expect(account.reload.dormant_warning_sent_at).to be_nil
    # Reset to zero, not decremented (review batch 2, P10): a decrement is
    # only right if this claim was the only one, and zero is the honest
    # statement of what happened — nobody has been warned about this date.
    expect(AccountCounter.where(account_id: account.id).pluck(:value)).to all(eq(0))

    allow(delivery).to receive(:deliver_now!).and_return(true)

    Accounts::Retention.schedule_dormant_warnings!

    expect(delivery).to have_received(:deliver_now!).twice
    expect(account.reload.dormant_warning_sent_at).to be_present
  end

  # The stamp is the evidence the purge relies on — "this customer was told, a
  # week ago" — and an enqueued job is not evidence of anything: it can fail
  # permanently afterwards, and the purge would then go ahead on a letter
  # nobody received. So the warning is DELIVERED inline and stamped only once
  # the mail server has taken it (review batch 2, R5).
  it 'does not become purgeable on a warning that was never actually delivered' do
    delivery = instance_double(ActionMailer::MessageDelivery)

    allow(AccountMailer).to receive(:dormant_warning).and_return(delivery)
    allow(delivery).to receive(:deliver_now!).and_raise(Net::SMTPServerBusy, 'mailbox unavailable')

    warn_finally!

    expect(account.reload.dormant_warning_sent_at).to be_nil

    travel_to(8.days.from_now) do
      expect(Accounts::Retention.purge_candidates.map(&:id)).not_to include(account.id)
    end

    # The mail server comes back and the letter really goes out; only then is
    # the account on the road to being purged.
    allow(delivery).to receive(:deliver_now!).and_return(true)

    warn_finally!

    expect(account.reload.dormant_warning_sent_at).to be_present
    expect(Accounts::Retention.purge_candidates.map(&:id)).to include(account.id)
  end

  # A warning belongs to ONE dormancy (review batch 2, P9). An account can go
  # quiet, be warned, come back to life, and go quiet again a year later — and
  # the letter from the first cycle must not authorize the second deletion, or
  # somebody who signed in after being warned would be deleted a year later
  # without ever hearing about it again.
  it 'refuses to purge on a warning that belongs to an earlier dormancy' do
    warn_finally!

    expect(Accounts::Retention.purge_candidates.map(&:id)).to include(account.id)

    # They came back. The old warning is now about a dormancy that ended.
    owner.update!(current_sign_in_at: Time.current, last_sign_in_at: Time.current)

    expect(Accounts::Retention.purge_candidates.map(&:id)).not_to include(account.id)

    # And the stale pin is cleared rather than left to be mistaken for
    # evidence about the next cycle.
    Accounts::Retention.schedule_dormant_warnings!

    expect(account.reload.dormant_warning_sent_at).to be_nil
    expect(account.dormant_warning_for).to be_nil

    # A year later they are dormant again — but this time the warning cannot
    # go out (the queue is down), so there is no evidence anybody was told.
    delivery = instance_double(ActionMailer::MessageDelivery)

    allow(AccountMailer).to receive(:dormant_warning).and_return(delivery)
    allow(delivery).to receive(:deliver_now!).and_raise(RuntimeError, 'the mail server is down')

    travel_to(13.months.from_now) do
      Accounts::Retention.schedule_dormant_warnings!

      expect(account.reload.dormant_warning_sent_at).to be_nil
      expect(Accounts::Retention.purge_candidates.map(&:id)).not_to include(account.id)
    end
  end

  it 'never touches a testing child on its own — it goes with its parent' do
    parent = create(:account, :with_testing_account, created_at: 3.years.ago)
    child = parent.testing_accounts.sole

    create(:user, account: parent, created_at: 3.years.ago, current_sign_in_at: 13.months.ago)
    warn_finally!(parent)

    expect(Accounts::Retention.purge_candidates.map(&:id)).to include(parent.id)
    expect(Accounts::Retention.purge_candidates.map(&:id)).not_to include(child.id)

    Accounts::Purge.call(parent)

    # The child keeps its row as a tombstone, like the parent (K2): deleting
    # it would leave verified_documents.account_id pointing at nothing.
    expect(child.reload.purged_at).to be_present
    expect(child.name).to eq(Accounts::Purge::TOMBSTONE_NAME)
    expect(parent.reload.purged_at).to be_present
  end
end
