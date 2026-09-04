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

  def request_deletion!(password: 'correct horse battery', confirm: '1')
    delete '/settings/account', params: { password:, confirm: }

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

    # Everything a real account carries, so the inventory walk is exercised
    # rather than described: documents with blobs, the projections behind
    # them, settings, counters and a second person.
    def populate!
      submission = send_one
      complete!(submission.submitters.first)

      create(:account_config, account:, key: AccountConfig::ALLOW_TO_DECLINE_KEY, value: true)
      create(:encrypted_config, account:, key: EncryptedConfig::ESIGN_CERTS_KEY, value: { 'cert' => 'x' })
      create(:user, account:, role: User::EDITOR_ROLE)
      AccountCounters.increment!(account.id, 'anything')
      SearchEntry.create!(account:, record: template, tsvector: template.name.to_s, ngram: template.name.to_s)
      WebhookEvent.create!(account:, webhook_url: webhook, uuid: SecureRandom.uuid,
                           event_type: 'form.completed', record_type: 'Submitter',
                           record_id: submission.submitters.first.id, status: 'error')

      submission
    end

    # What the inventory walk is supposed to have emptied, table by table.
    def remaining_rows(submission)
      submitter_ids = submission.submitters.ids
      user_ids = User.where(account_id: account.id).select(:id)

      { templates: Template.where(account_id: account.id).count,
        submissions: Submission.where(account_id: account.id).count,
        submission_events: SubmissionEvent.where(account_id: account.id).count,
        submitter_versions: SubmitterVersion.where(submitter_id: submitter_ids).count,
        completed_documents: CompletedDocument.where(submitter_id: submitter_ids).count,
        template_folders: TemplateFolder.where(account_id: account.id).count,
        document_metadata: DocumentMetadata.where(account_id: account.id).count,
        email_messages: EmailMessage.where(account_id: account.id).count,
        email_events: EmailEvent.where(account_id: account.id).count,
        webhook_urls: WebhookUrl.where(account_id: account.id).count,
        account_configs: AccountConfig.where(account_id: account.id).count,
        encrypted_configs: EncryptedConfig.where(account_id: account.id).count,
        account_counters: AccountCounter.where(account_id: account.id).count,
        access_tokens: AccessToken.where(user_id: user_ids).count }
    end

    it 'destroys the inventory, releases the email, keeps the /verify record and leaves a tombstone',
       sidekiq: :inline do
      submission = populate!
      admin_email = admin.email
      blob_ids = ActiveStorage::Attachment.where(record_type: 'Template', record_id: template.id).pluck(:blob_id)
      verified = VerifiedDocument.where(submission_id: submission.id).to_a

      expect(blob_ids).not_to be_empty
      expect(verified).not_to be_empty

      account.update!(deletion_requested_at: 90.days.ago, purge_scheduled_for: 1.minute.ago)

      expect(Accounts::Purge.call(account)).to eq(:purged)

      # Every table of the inventory, in one measurement, so a table that
      # survived is named in the failure rather than hidden behind the first
      # assertion that happened to be written.
      remaining = remaining_rows(submission)

      expect(remaining).to eq(remaining.transform_values { 0 })

      # The files, not only the rows.
      expect(ActiveStorage::Blob.where(id: blob_ids).count).to eq(0)
      expect(ActiveStorage::Attachment.where(blob_id: blob_ids).count).to eq(0)

      # Nothing left pointing at the account in the four tables the database
      # itself would not have complained about.
      expect(Accounts::Purge.orphans(account.id).values).to all(eq(0))

      # The people are gone and the address can be registered again.
      expect(User.where(account_id: account.id).count).to eq(0)
      expect(User.exists?(email: admin_email)).to be(false)

      # /verify keeps working forever — the record names nobody.
      verified.each do |record|
        expect(VerifiedDocument.find_by(id: record.id)).to have_attributes(
          sha256: record.sha256, signers_count: record.signers_count, signed_at: record.signed_at
        )
      end

      # The tombstone.
      account.reload

      expect(account.name).to eq(Accounts::Purge::TOMBSTONE_NAME)
      expect(account.purged_at).to be_present
      expect(account.archived_at).to be_present
      expect(account.uuid).to be_present

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
  end
end

# Accounts nobody uses (D43): a year of silence, three warnings, then the same
# purge.
RSpec.describe 'Accounts nobody signs in to', type: :request do
  let(:account) { create(:account, created_at: 3.years.ago) }
  let!(:owner) { create(:user, account:, created_at: 3.years.ago, current_sign_in_at: 13.months.ago) }
  let(:deliveries) { ActionMailer::Base.deliveries }

  before { deliveries.clear }

  it 'is a purge candidate after a year of silence, and is not one the day after somebody signs in' do
    expect(Accounts::Retention.purge_candidates.map(&:id)).to include(account.id)

    owner.update!(current_sign_in_at: 1.day.ago)

    expect(Accounts::Retention.purge_candidates.map(&:id)).not_to include(account.id)
  end

  # A paid account is never dormant, and a cancelled one is protected for a
  # year after the money stopped — the promise is about the documents, not
  # about how often anybody logs in.
  it 'is never a candidate while it pays, nor within a year of the subscription ending' do
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

    [61, 60, 45, 30, 20, 7, 3].each do |days_before|
      travel_to(purge_at - days_before.days) { Accounts::Retention.schedule_dormant_warnings! }
    end

    warnings = deliveries.select { |m| m.subject.include?('unused EsignCenter account') }

    expect(warnings.map { |m| m.subject[/in (\d+) days/, 1].to_i }).to eq([60, 30, 7])
    expect(warnings.first.to).to contain_exactly(owner.email)
    expect(warnings.last.body.encoded).to include(Accounts::Deletion.format_date(purge_at))

    travel_to(purge_at + 1.hour) do
      expect(Accounts::Retention.purge_candidates.map(&:id)).to include(account.id)

      perform_enqueued_jobs(only: AccountPurgeJob) { Accounts::Retention.purge_due! }
    end

    expect(account.reload.purged_at).to be_present
    expect(User.where(account_id: account.id).count).to eq(0)
  end

  it 'never touches a testing child on its own — it goes with its parent' do
    parent = create(:account, :with_testing_account, created_at: 3.years.ago)
    child = parent.testing_accounts.sole

    create(:user, account: parent, created_at: 3.years.ago, current_sign_in_at: 13.months.ago)

    expect(Accounts::Retention.purge_candidates.map(&:id)).to include(parent.id)
    expect(Accounts::Retention.purge_candidates.map(&:id)).not_to include(child.id)

    Accounts::Purge.call(parent)

    expect(Account.exists?(child.id)).to be(false)
    expect(parent.reload.purged_at).to be_present
  end
end
