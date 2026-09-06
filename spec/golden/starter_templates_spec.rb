# frozen_string_literal: true

# Four ready-made documents land in a brand-new customer account (D50), from
# BOTH self-serve doors and from nowhere else — not an invitation, not the
# provisioning API, not an internal account. They are stored through the same
# path an upload takes, they cost the account nothing, and one of them can be
# sent and signed the moment the person arrives.
RSpec.describe 'Starter templates', type: :request do
  stash_env 'REGISTRATION_ENABLED', 'TURNSTILE_SITE_KEY', 'TURNSTILE_SECRET_KEY',
            'GOOGLE_OAUTH_CLIENT_ID', 'GOOGLE_OAUTH_CLIENT_SECRET', 'ADMIN_PROVISION_TOKEN', clear: true

  let(:admin_token) { 'golden-starter-provision-token' }

  before do
    create(:user, account: create(:account, :operator))
    RateLimit.store.clear
    ENV['REGISTRATION_ENABLED'] = 'true'
    ENV['TURNSTILE_SITE_KEY'] = 'turnstile-site-key'
    ENV['TURNSTILE_SECRET_KEY'] = 'turnstile-secret-key'
    stub_turnstile
  end

  after do
    RateLimit.store.clear
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end

  def sign_up(email: 'ada@example.com')
    post registration_path,
         params: { user: { name: 'Ada Lovelace', email:, password: 'a-long-password', timezone: 'Europe/Paris' },
                   'cf-turnstile-response' => 'turnstile-token', **LegalDocuments.version_fields }
  end

  # The Google door, driven the way spec/golden/signup_spec.rb drives it: the
  # POST-only authorize endpoint, then the callback the controller runs in.
  def sign_up_with_google!(email: 'grace@example.com')
    ENV['GOOGLE_OAUTH_CLIENT_ID'] = 'google-client-id'
    ENV['GOOGLE_OAUTH_CLIENT_SECRET'] = 'google-client-secret'

    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] =
      OmniAuth::AuthHash.new(provider: 'google_oauth2', uid: '10769150350006150715113082367',
                             info: { email:, name: 'Grace Hopper' },
                             extra: { raw_info: { email_verified: true } })

    post user_google_oauth2_omniauth_authorize_path(LegalDocuments.version_fields)

    expect(response).to have_http_status(:redirect)

    follow_redirect!
  end

  def account_for(email)
    User.find_by!(email:).account
  end

  def starter_names
    StarterTemplates.manifest.pluck('name')
  end

  describe 'the email sign-up door' do
    # (a) The whole of what a seeded account holds: four templates at the top
    # level, each with its document, its preview images and its fields, and
    # every field's rectangle inside the page it names.
    it 'seeds the four starter templates, stored exactly as an upload would be', sidekiq: :inline do
      expect { sign_up }.to change(Template, :count).by(4)

      account = account_for('ada@example.com')
      templates = account.templates.order(:id)

      expect(templates.map(&:name)).to match_array(starter_names)
      expect(templates.map { |t| t.preferences['starter'] }).to all(be(true))
      expect(templates.map(&:author_id).uniq).to eq([account.users.sole.id])
      expect(templates.map(&:folder_id).uniq).to eq([account.default_template_folder.id])
      expect(account.account_configs.find_by(key: AccountConfig::STARTER_TEMPLATES_SEEDED_KEY)).to be_present

      templates.each do |template|
        document = template.documents.sole

        expect(document.content_type).to eq('application/pdf')
        expect(template.schema.sole['attachment_uuid']).to eq(document.uuid)
        expect(document.metadata.dig('pdf', 'number_of_pages')).to be_positive
        expect(document.metadata['sha256']).to be_present

        previews = ActiveStorage::Attachment.where(name: 'preview_images', record: document)

        expect(previews.count).to eq(document.metadata.dig('pdf', 'number_of_pages'))

        expect(template.fields).not_to be_empty
        expect(template.fields.pluck('type').uniq).to all(be_in(%w[text date signature initials checkbox]))
        expect(template.fields.pluck('uuid').uniq.size).to eq(template.fields.size)

        submitter_uuids = template.submitters.pluck('uuid')

        template.fields.each do |field|
          expect(field['submitter_uuid']).to be_in(submitter_uuids)

          area = field['areas'].sole

          expect(area['attachment_uuid']).to eq(document.uuid)
          expect(area['page']).to be_between(0, document.metadata.dig('pdf', 'number_of_pages') - 1)
          expect(area['x']).to be_between(0, 1)
          expect(area['y']).to be_between(0, 1)
          expect(area['x'] + area['w']).to be <= 1
          expect(area['y'] + area['h']).to be <= 1
        end
      end
    end

    it 'shows them on the dashboard the moment the person signs in', sidekiq: :inline do
      sign_up

      user = User.find_by!(email: 'ada@example.com')
      user.confirm
      sign_in(user)

      get root_path

      expect(response).to have_http_status(:ok)
      starter_names.each { |name| expect(response.body).to include(ERB::Util.html_escape(name)) }
    end
  end

  # (b) The Google door seeds by construction: both doors save through
  # Registrations.save_signup, which is where the job is enqueued.
  describe 'the Google sign-up door' do
    it 'seeds the same four templates', sidekiq: :inline do
      expect { sign_up_with_google! }.to change(Template, :count).by(4)

      expect(account_for('grace@example.com').templates.map(&:name)).to match_array(starter_names)
    end

    it 'seeds nothing for an existing user signing in again', sidekiq: :inline do
      account = create(:account)
      create(:user, account:, email: 'returning@example.com')

      expect { sign_up_with_google!(email: 'returning@example.com') }.not_to change(Template, :count)
    end
  end

  # (c) Every other door that makes an account or a user.
  describe 'doors that seed nothing' do
    it 'seeds nothing when an invitation is accepted', sidekiq: :inline do
      # A seat has to be free for the invitation to be accepted at all, so the
      # account pays for two.
      account = create(:account)

      create(:user, account:)
      create(:account_subscription, account:, access_state: 'active', status: 'active',
                                    stripe_status: 'active', quantity: 2,
                                    current_period_end: 20.days.from_now)

      invite = create(:account_invite, account:, role: User::EDITOR_ROLE)
      token = invite.raw_token

      expect do
        post "/invites/#{token}", params: { first_name: 'Sam', last_name: 'Rivers', password: 'password-123',
                                            **LegalDocuments.version_fields }
      end.to change(User, :count).by(1)

      expect(invite.reload.accepted_at).to be_present
      expect(account.templates.count).to eq(0)
    end

    it 'seeds nothing for a provisioned internal account', sidekiq: :inline do
      ENV['ADMIN_PROVISION_TOKEN'] = admin_token

      expect do
        post '/api/admin/accounts',
             headers: { 'x-admin-token': admin_token, 'content-type': 'application/json' },
             params: { name: 'Provisioned Firm', email: 'provisioned@example.com' }.to_json
      end.to change(Account, :count).by(1)

      expect(response).to have_http_status(:created)

      account = Account.order(:id).last

      expect(account.account_kind).to eq(Account::INTERNAL_KIND)
      expect(account.templates.count).to eq(0)
    end

    # `rake operator:seed` and every other internal/operator kind: the job
    # itself refuses them, whoever asks.
    it 'refuses an internal or operator account even when the job is run directly' do
      %i[internal operator].each do |kind|
        account = create(:account, kind)

        create(:user, account:)

        expect { StarterTemplatesJob.new.perform(account.id) }.not_to change(Template, :count)
        expect(account.account_configs.count).to eq(0)
      end
    end
  end

  # (d) Idempotent: the marker, and "this account already holds a template".
  describe 'running twice' do
    let(:account) { create(:account) }

    before { create(:user, account:) }

    it 'creates nothing the second time' do
      expect { StarterTemplatesJob.new.perform(account.id) }.to change(Template, :count).by(4)
      expect { StarterTemplatesJob.new.perform(account.id) }.not_to change(Template, :count)
    end

    it 'declines an account that already holds a template of its own' do
      create(:template, account:, author: account.users.sole)

      expect { StarterTemplatesJob.new.perform(account.id) }.not_to change(Template, :count)
      expect(account.account_configs.count).to eq(0)
    end
  end

  # (e) Storage refuses, the disk is full, anything: the sign-up is untouched.
  describe 'when seeding fails' do
    it 'leaves the sign-up intact, reports it, and writes no half-seeded account', sidekiq: :inline do
      allow(Templates::CreateAttachments).to receive(:call).and_raise(StandardError, 'storage is down')
      allow(ErrorReport).to receive(:error).and_call_original

      expect { sign_up }.to change(User, :count).by(1)
      expect(response).to redirect_to(confirm_registration_path)

      account = account_for('ada@example.com')

      expect(account.templates.count).to eq(0)
      expect(account.account_configs.count).to eq(0)
      expect(ErrorReport).to have_received(:error).with(instance_of(StandardError), account_id: account.id)
    end
  end

  # --- review 1 regressions --------------------------------------------------

  describe 'when the QUEUE is down (Codex 3)' do
    # The job swallows its own failures once it runs; a failure to ENQUEUE it
    # happens out in Registrations.save_signup, after the account has been
    # created, and used to escape into the sign-up response — a person left
    # with a 500, an account that exists and an address that is now taken.
    it 'still completes the sign-up, and reports the enqueue failure' do
      allow(StarterTemplatesJob).to receive(:perform_later).and_raise(StandardError, 'redis is down')
      allow(ErrorReport).to receive(:error).and_call_original

      expect { sign_up }.to change(User, :count).by(1)

      expect(response).to redirect_to(confirm_registration_path)
      account = account_for('ada@example.com')
      expect(account.templates.count).to eq(0)
      expect(ErrorReport).to have_received(:error).with(instance_of(StandardError), account_id: account.id)
    end

    it 'reports it on the Google door too, where the failure would swallow the sign-in' do
      allow(StarterTemplatesJob).to receive(:perform_later).and_raise(StandardError, 'redis is down')
      allow(ErrorReport).to receive(:error).and_call_original

      sign_up_with_google!

      expect(User.find_by(email: 'grace@example.com')).to be_present
      expect(ErrorReport).to have_received(:error).with(instance_of(StandardError), account_id: anything)
    end
  end

  describe 'a headless caller (Codex 6)' do
    # `save_signup` supports `source: nil` for a console or a provisioning
    # script — a caller with no human in front of it. A script that creates a
    # customer account is not somebody who needs four sample documents.
    it 'seeds nothing when the save names no self-serve door' do
      user = Registrations.build_signup(name: 'Head Less', email: 'headless@example.com',
                                        password: 'a-long-password', timezone: 'UTC')

      allow(StarterTemplatesJob).to receive(:perform_later).and_call_original

      expect(Registrations.save_signup(user, source: nil)).to be(true)
      expect(user.account).to be_customer
      expect(StarterTemplatesJob).not_to have_received(:perform_later)
      expect(user.account.templates.count).to eq(0)
    end

    it 'seeds for each of the two doors the feature is for' do
      allow(StarterTemplatesJob).to receive(:perform_later).and_call_original

      Registrations::SELF_SERVE_SOURCES.each_with_index do |source, index|
        user = Registrations.build_signup(name: 'Door Person', email: "door#{index}@example.com",
                                          password: 'a-long-password', timezone: 'UTC')

        expect(Registrations.save_signup(user, source:, versions: LegalDocuments.current_versions)).to be(true)
        expect(StarterTemplatesJob).to have_received(:perform_later).with(user.account_id)
      end

      expect(Registrations::SELF_SERVE_SOURCES)
        .to eq([LegalAcceptance::SIGNUP_EMAIL, LegalAcceptance::SIGNUP_GOOGLE])
    end
  end

  describe 'two workers racing the same new account (L4)' do
    let(:account) { create(:account) }

    before { create(:user, account:) }

    # The marker's unique index is what makes the race safe, and the loser
    # raising RecordNotUnique is the idempotency working — not something to
    # wake an operator for.
    it 'declines quietly rather than reporting a benign duplicate' do
      allow(ErrorReport).to receive(:error).and_call_original
      account.account_configs.create!(key: AccountConfig::STARTER_TEMPLATES_SEEDED_KEY, value: {})

      # The marker check happens before the transaction, so this is the loser
      # arriving with the marker already written under it.
      allow(StarterTemplates).to receive(:seeded?).and_return(false)

      expect { StarterTemplatesJob.new.perform(account.id) }.not_to change(Template, :count)

      expect(ErrorReport).not_to have_received(:error)
    end

    # And only THAT index (session 10, seam L2). The rescue covers the whole
    # method — the marker, four templates, their attachments, the document
    # processing and the reindex — so a unique-index bug in any of them used
    # to come back as the same well-formed shrug: nothing raised, no
    # ErrorReport, and an account silently left with no documents. A duplicate
    # that is not the marker's is a bug, and a bug is reported.
    it 'reports a duplicate that is not the marker rather than filing it as the race' do
      allow(ErrorReport).to receive(:error).and_call_original
      allow(Templates::CreateAttachments).to receive(:call)
        .and_raise(ActiveRecord::RecordNotUnique,
                   'PG::UniqueViolation: ERROR: duplicate key value violates unique constraint ' \
                   '"index_active_storage_blobs_on_key"')

      expect { StarterTemplatesJob.new.perform(account.id) }.not_to change(Template, :count)

      expect(account.account_configs.count).to eq(0)
      expect(ErrorReport).to have_received(:error).with(instance_of(ActiveRecord::RecordNotUnique),
                                                        account_id: account.id)
    end
  end

  # (f) The point of the whole feature: a seeded template is a real one.
  describe 'sending a seeded template' do
    it 'sends the mutual NDA and produces a signed PDF', sidekiq: :inline do
      platform_certificate!
      sign_up

      account = account_for('ada@example.com')
      admin = account.users.sole
      template = account.templates.find_by!(name: 'Mutual Non-Disclosure Agreement')

      expect(template.submitters.pluck('name')).to eq(['First Party', 'Second Party'])

      submission = Submissions.create_from_emails(template:, user: admin, emails: 'first@example.com',
                                                  source: :invite, mark_as_sent: true).sole

      submitter = complete_every_field!(submission.submitters.sole)

      expect(submitter.completed_at).to be_present
      expect(submitter.documents).to be_present
      expect(submitter.documents.first.download[0, 5]).to eq('%PDF-')
      expect(CompletedSubmitter.where(account_id: account.id).count).to eq(1)
    end

    # A signer answers every required blank the manifest laid down — text,
    # date, checkbox, and a real drawn signature stored the way the signing
    # form stores one.
    def complete_every_field!(submitter)
      fields = submitter.submission.template_fields.presence || submitter.submission.template.fields
      values =
        fields.select { |f| f['submitter_uuid'] == submitter.uuid && f['required'] }.to_h do |field|
          [field['uuid'], value_for(submitter, field['type'])]
        end

      expect(values.size).to be_positive

      # The same consent envelope spec/support/signing_helpers.rb posts; this
      # one spells the PUT out because it fills every field type, not one.
      put "/s/#{submitter.slug}", params: { completed: 'true', esign_consent: 'true',
                                            esign_consent_version: EsignConsent::VERSION,
                                            esign_consent_locale: EsignConsent.rendered_locale,
                                            esign_consent_locale_token:
                                              EsignConsent.locale_token(submitter, EsignConsent.rendered_locale),
                                            esign_consent_sender_digest: EsignConsent.sender_digest(submitter),
                                            values: }

      expect(response).to have_http_status(:ok)

      submitter.reload
    end

    def value_for(submitter, type)
      case type
      when 'date' then '2026-01-01'
      when 'checkbox' then true
      when 'signature', 'initials' then drawn_mark(submitter).uuid
      else 'Ada Lovelace'
      end
    end

    def drawn_mark(submitter)
      ActiveStorage::Attachment.create!(
        name: 'attachments', record: submitter,
        blob: ActiveStorage::Blob.create_and_upload!(io: Rails.root.join('spec/fixtures/sample-image.png').open,
                                                     filename: 'signature.png', content_type: 'image/png')
      )
    end
  end

  # (g) Seeding is not usage: it costs the account nothing at all.
  describe 'what seeding costs the account' do
    let(:account) { create(:account) }

    before { create(:user, account:) }

    it 'writes no completion, spends no send and leaves every counter at zero' do
      expect { StarterTemplatesJob.new.perform(account.id) }.not_to change(CompletedSubmitter, :count)
      expect { StarterTemplatesJob.new.perform(account.id) }.not_to change(Submission, :count)
      expect(Submitter.count).to eq(0)
      expect(AccountCounter.count).to eq(0)

      expect(Quotas.completions_this_month(account)).to eq(0)
      expect(Quotas.sends_this_month(account)).to eq(0)
      expect(Quotas.in_flight(account)).to eq(0)
      expect(AccountCounters.value(account.id, 'submissions_created')).to eq(0)
    end
  end
end
