# frozen_string_literal: true

# What happens to an account whose card keeps failing (D43/D57), and what
# deliberately does NOT.
#
# The rule this file protects: a suspended account is frozen for WRITES and
# nothing else. Everyone can still sign in, read, download and export; a
# signer already part-way through a document still finishes it and that
# completion is still metered; only creating and changing stops, on every
# door including the tokens. Paying lifts it by itself, within seconds.
#
# Archiving is the opposite policy and is asserted here too: archived means
# the account is gone, so the signer write paths stop as well.
#
# Every completion is a REAL one (a signer's PUT /s/:slug with consent,
# SigningHelpers#complete!) under `sidekiq: :inline`; no metering row is ever
# inserted by hand. Stripe is never called: the subscription states come from
# real CLI captures (spec/fixtures/stripe) fed to the ONE mapping every
# Stripe door shares (StripeBilling::SubscriptionSync.apply!).
RSpec.describe 'Account suspension', type: :request do # rubocop:disable RSpec/MultipleDescribes
  let(:account) { create(:account, :paid) }
  let(:admin) { create(:user, account:) }
  let(:template) { create(:template, account:, author: admin, only_field_types: %w[text]) }
  let(:deliveries) { ActionMailer::Base.deliveries }

  before do
    platform_certificate!
    deliveries.clear
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
    "signer-#{SecureRandom.hex(4)}@example.com"
  end

  def suspend!(record = account, reason: 'billing')
    expect(AccountStates.suspend!(record, reason:)).to be(true)

    record.reload
  end

  def send_one(email: unique_email)
    Submissions.create_from_emails(template:, user: admin, emails: email, source: :invite,
                                   mark_as_sent: true).sole
  end

  describe 'what a suspended account can no longer do' do
    before do
      template
      suspend!
      act_as(admin)
    end

    it 'refuses a new template' do
      expect { post '/templates', params: { template: { name: 'While suspended' } } }
        .not_to change(Template, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to be_present
    end

    it 'refuses a change to an existing template' do
      expect { put "/templates/#{template.id}", params: { template: { name: 'Renamed' } } }
        .not_to(change { template.reload.name })

      expect(response).to redirect_to(root_path)
    end

    it 'refuses an invitation to a new person' do
      expect do
        post '/users', params: { user: { email: unique_email, first_name: 'New',
                                         last_name: 'Person', role: 'admin' } }
      end.not_to change(User, :count)

      expect(response).to redirect_to(root_path)
    end

    it 'refuses a new document from the recipients form, creating nothing' do
      expect do
        post "/templates/#{template.id}/submissions", params: { emails: unique_email, send_email: '1' }
      end.not_to change(Submission, :count)

      expect(response).to redirect_to(root_path)
    end

    it 'refuses a new webhook and a new MCP token' do
      expect { post '/settings/webhooks', params: { webhook_url: { url: 'https://example.com/hook' } } }
        .not_to change(WebhookUrl, :count)

      create(:account_config, account:, key: AccountConfig::ENABLE_MCP_KEY, value: true)

      expect { post '/settings/mcp', params: { mcp_token: { name: 'While suspended' } } }
        .not_to change(McpToken, :count)
    end

    # The chokepoint every non-CanCan creation path shares refuses too, with
    # its own sentence — so a door added later cannot forget the rule.
    it 'refuses at the quota chokepoint, on the paid plan, with the suspension message' do
      expect { Quotas.assert_can_create_submissions!(account) }
        .to raise_error(Quotas::LimitReached) { |e| expect(e.reason).to eq(:suspended) }

      expect(Quotas.share_link_paused?(account)).to eq(:suspended)
      expect(Quotas.message_for(:suspended)).to eq(I18n.t('account_suspended_alert'))
      expect(Quotas.pause_message(account, :suspended)).to eq(I18n.t('account_suspended_alert'))
    end

    it 'never refuses an internal account, whatever the state of its columns' do
      internal = create(:account, :internal)

      expect(AccountStates.suspend!(internal, reason: 'billing')).to be(false)
      expect(Quotas.assert_can_create_submissions!(internal)).to be(true)
    end
  end

  describe 'the share link of a suspended account' do
    before do
      template.update!(shared_link: true)
      suspend!
      anonymous!
    end

    it 'shows the ordinary closed page rather than a missing translation' do
      get "/d/#{template.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('form_not_accepting_responses'))
      expect(response.body).not_to include('translation missing')
    end

    it 'refuses the PUT that would start a document, creating nothing' do
      expect { put "/d/#{template.slug}", params: { submitter: { email: unique_email } } }
        .not_to change(Submission, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('form_not_accepting_responses'))
    end
  end

  describe 'what a suspended account can still do' do
    let!(:submission) { send_one }

    it 'reads the templates list and shows the banner with the way to fix it', sidekiq: :inline do
      suspend!
      act_as(admin)

      get '/templates'

      expect(response).to have_http_status(:ok)

      doc = Nokogiri::HTML(response.body)

      expect(doc.at('[data-account-suspended-banner]').text).to include(I18n.t('account_suspended_banner'))
      expect(doc.at('[data-account-suspended-link]')['href']).to eq('/settings/billing')
    end

    it 'downloads a completed document and exports the CSV', sidekiq: :inline do
      complete!(submission.submitters.first)
      suspend!
      act_as(admin)

      get "/submissions/#{submission.id}/download"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to be_present

      get "/templates/#{template.id}/submissions_export.csv"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(submission.submitters.first.email)
    end

    it 'lets an in-flight signer finish, and still meters the completion', sidekiq: :inline do
      submitter = submission.submitters.first
      suspend!
      anonymous!

      get "/s/#{submitter.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t('form_has_been_archived'))

      complete!(submitter)

      expect(submitter.reload.completed_at).to be_present
      expect(Quotas.completions_this_month(account)).to eq(1)
      expect(CompletedSubmitter.find_by!(submitter:).is_first).to be(true)
    end

    it 'lets the admin reach the billing page and their own profile' do
      suspend!
      act_as(admin)

      get '/settings/profile'

      expect(response).to have_http_status(:ok)

      expect { put "/users/#{admin.id}", params: { user: { first_name: 'Still' } } }
        .to(change { admin.reload.first_name }.to('Still'))
    end
  end

  # Reviewer findings E3 and B2: what a frozen page must NOT show. A banner
  # saying "nothing new can be created" above an upload dropzone is a page
  # arguing with itself; a banner that names a payment problem is wrong when
  # the account was suspended by us and right only when it was the card; and a
  # person whose SEAT went in a downgrade was told nothing at all, then met
  # CanCan's own untranslated "You are not authorized to access this page."
  describe 'the read-only surfaces' do
    def dashboard_doc
      get '/templates'

      expect(response).to have_http_status(:ok)

      Nokogiri::HTML(response.body)
    end

    it 'invites a suspended account to upload nothing: no dropzone, no Upload, no Create' do
      template
      suspend!
      act_as(admin)

      doc = dashboard_doc

      expect(doc.at('[data-account-suspended-banner]')).to be_present
      expect(doc.at('file-dropzone')).to be_nil
      expect(doc.at('#dashboard_dropzone_input')).to be_nil
      expect(doc.at('#upload_template')).to be_nil
      expect(doc.at("a[href='/templates/new']")).to be_nil
      expect(doc.text).not_to include(I18n.t('upload_a_new_document'))
    end

    it 'sends an operator suspension to support instead of to a payment form' do
      template
      suspend!(reason: 'operator')
      act_as(admin)

      doc = dashboard_doc
      banner = doc.at('[data-account-suspended-banner]')

      expect(banner.text).to include(I18n.t('account_suspended_banner_operator'))
      expect(banner.text).to include(I18n.t('account_suspended_banner_operator_hint'))
      expect(banner.text).not_to include(I18n.t('account_suspended_banner'))
      expect(doc.at('[data-account-suspended-link]')['href']).to eq("mailto:#{Docuseal::SUPPORT_EMAIL}")
    end

    it 'tells a member parked read-only by a downgrade why, and offers them no upload either' do
      template
      parked = create(:user, account:, role: User::EDITOR_ROLE, read_only_at: Time.current)

      act_as(parked)

      doc = dashboard_doc
      banner = doc.at('[data-seat-read-only-banner]')

      expect(doc.at('[data-account-suspended-banner]')).to be_nil
      expect(banner.text).to include(I18n.t('seat_read_only_banner'))
      expect(banner.text).to include(I18n.t('seat_read_only_banner_hint'))
      expect(doc.at('file-dropzone')).to be_nil
      expect(doc.at('#dashboard_dropzone_input')).to be_nil
      expect(doc.at('#upload_template')).to be_nil
      expect(doc.text).not_to include(I18n.t('upload_a_new_document'))
    end

    # Reviewer Q (finding Q2): taking the dropzone away left the CARDS still
    # registered as drop targets, so a read-only reader who dropped a file on
    # one got a greyed-out card with a spinner that never stopped and a
    # JavaScript exception, where before they at least got a sentence back
    # from the server. The card only carries the drop target when the person
    # could create the template the drop would make.
    it 'leaves no drop target on the cards a read-only reader can see' do
      template
      folder = create(:template_folder, :with_templates, account:, author: admin)

      # An account with documents in it is not five minutes old; kept out of
      # the first-fortnight app tour so the healthy leg renders the plain
      # dashboard the comparison is about.
      admin.update!(created_at: 3.weeks.ago)

      act_as(admin)

      doc = dashboard_doc

      expect(doc.css('[data-targets~="dashboard-dropzone.templateCards"]')).not_to be_empty
      expect(doc.css('[data-targets~="dashboard-dropzone.folderCards"]')).not_to be_empty
      expect(doc.text).to include(folder.name)

      parked = create(:user, account:, role: User::EDITOR_ROLE, read_only_at: Time.current)

      act_as(parked)

      doc = dashboard_doc

      expect(doc.text).to include(template.name)
      expect(doc.text).to include(folder.name)
      expect(doc.css('[data-targets~="dashboard-dropzone.templateCards"]')).to be_empty
      expect(doc.css('[data-targets~="dashboard-dropzone.folderCards"]')).to be_empty

      suspend!
      act_as(admin)

      doc = dashboard_doc

      expect(doc.css('[data-targets~="dashboard-dropzone.templateCards"]')).to be_empty
      expect(doc.css('[data-targets~="dashboard-dropzone.folderCards"]')).to be_empty
    end

    it 'answers a refused write with a plain translated sentence, not CanCan\'s own' do
      parked = create(:user, account:, role: User::EDITOR_ROLE, read_only_at: Time.current)

      act_as(parked)

      expect { post '/templates', params: { template: { name: 'While parked' } } }
        .not_to change(Template, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t('access_denied_alert'))
      expect(flash[:alert]).not_to include('not authorized to access this page')
    end
  end

  # Archived is the OTHER policy, and until Session 7 the signer write paths
  # did not check it at all: the locked page was rendered by `show` while the
  # PUT behind it still went through (Session 2 handoff). Archived means the
  # account is gone, so those writes stop too.
  describe 'an archived account, whose signer writes stop as well' do
    let!(:submission) { send_one }
    let(:submitter) { submission.submitters.first }

    before do
      account.update!(archived_at: Time.current)
      anonymous!
    end

    it 'refuses the signing PUT' do
      put "/s/#{submitter.slug}", params: { completed: 'true', esign_consent: 'true',
                                            esign_consent_version: EsignConsent::VERSION,
                                            values: { text_field(submitter)['uuid'] => 'Jane' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => I18n.t('form_has_been_archived'))
      expect(submitter.reload.completed_at).to be_nil
    end

    it 'refuses a decline' do
      post "/s/#{submitter.slug}/decline", params: { reason: 'No thanks' }

      expect(submitter.reload.declined_at).to be_nil
    end

    it 'refuses a delegation' do
      create(:account_config, account:, key: AccountConfig::ALLOW_TO_DELEGATE_KEY, value: true)

      expect { post "/s/#{submitter.slug}/delegate", params: { email: unique_email } }
        .not_to change(SubmitterVersion, :count)
    end

    # Review batch 1, F8: the "invite another party" step of an
    # invite-then-complete signing writes new submitters into the account and
    # completes the signer, and it was the one signer write door that never
    # asked whether the account was still there.
    it 'refuses inviting another party into the document' do
      expect do
        post "/s/#{submitter.slug}/invite", params: {
          submission: { submitters: [{ uuid: SecureRandom.uuid, email: unique_email }] }
        }
      end.not_to change(Submitter, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(submitter.reload.completed_at).to be_nil
    end

    it 'refuses an attachment upload' do
      post '/api/attachments', params: {
        submitter_slug: submitter.slug,
        file: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/sample-image.png'), 'image/png')
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => I18n.t('form_has_been_archived'))
    end
  end

  # Review batch 1, F3. CanCan never looks at a `cannot :create` rule when the
  # question asked is `authorize!(:manage, thing)` — the actions have to match
  # — so every door shaped that way walked straight through the read-only
  # layer: rotating the API token, the testing-share toggle, uploading a logo,
  # renaming or deleting the account, and buying a seat with the card that had
  # just failed.
  #
  # The sweep is written off the ROUTE TABLE rather than off a list somebody
  # remembered to update: every write route under /settings has to be
  # classified here, so a new one fails this spec until a person has decided
  # which side of the line it is on.
  describe 'every write door of a suspended account' do
    # The doors that stay OPEN, and why. Nothing goes on this list without a
    # reason that survives being read aloud.
    let(:allowed_while_suspended) do
      {
        'billing_settings#checkout' => 'the page that settles the payment',
        'billing_settings#portal' => 'the page that settles the payment',
        # Session 7 Phase C (D43). Asking to be deleted is how a customer
        # LEAVES, and a customer whose card kept failing must be able to walk
        # away rather than being held on a plan they cannot pay for — so this
        # is the one write on the account row a suspended admin may still
        # make. It takes nothing away either: the account is already frozen,
        # and the deletion only adds a date 90 days out.
        'accounts#destroy' => 'requesting deletion is how a frozen account leaves',
        'accounts#cancel_deletion' => 'changing your mind about leaving must never be the door that is shut',
        'accounts#deletion_code' => 'the second way to confirm leaving; it emails the admin a code and writes nothing',
        # Session 8 phase D. Taking your data with you is the other half of
        # being allowed to leave: a frozen account can still ask for the zip
        # of everything, and the download door is a GET.
        'account_exports#create' => 'asking for an export of your own data is never the door that is shut',
        'profile#update_contact' => 'their own name and email are theirs',
        'profile#update_password' => 'their own password is theirs',
        'mfa_setup#create' => 'their own two-factor enrolment; a security door, not an account write',
        'mfa_setup#destroy' => 'their own two-factor enrolment',
        'reveal_access_token#create' => 'shows an existing token after a password check; changes nothing',
        'user_configs#create' => 'a personal UI preference (UserConfig is outside the layer by design)',
        'encrypted_user_configs#destroy' => 'their own stored signature material',
        'user_signatures#update' => 'their own saved signature',
        'user_signatures#destroy' => 'their own saved signature',
        'user_initials#update' => 'their own saved initials',
        'user_initials#destroy' => 'their own saved initials'
      }
    end

    # Doors no customer administrator can reach AT ALL: the operator gate is
    # in front of them, so the suspension layer is not what stands in the way.
    let(:operator_only) do
      {
        'search_entries_reindex#create' => 'require_operator_access!',
        'timestamp_server#create' => 'require_operator_access!',
        'esign_settings#create' => 'require_operator_access!',
        'esign_settings#update' => 'require_operator_access!',
        'esign_settings#destroy' => 'require_operator_access!',
        # The Session 8 operator console. Every one of these acts on an account
        # the OPERATOR picked, never on the acting user's own, and the whole
        # namespace is behind Operator::BaseController's prepended gate — so a
        # customer administrator, suspended or not, has no route to any of them
        # (spec/golden/operator_console_spec.rb drives that for real).
        'operator/accounts#suspend' => 'require_operator_access!',
        'operator/accounts#lift_suspension' => 'require_operator_access!',
        'operator/accounts#resume_sending' => 'require_operator_access!',
        'operator/accounts#cancel_deletion' => 'require_operator_access!',
        'operator/accounts#purge' => 'require_operator_access!',
        'operator/accounts#release_purge_claim' => 'require_operator_access!',
        'operator/accounts#comp_grant' => 'require_operator_access!',
        'operator/accounts#comp_revoke' => 'require_operator_access!',
        'operator/accounts#limits' => 'require_operator_access!',
        # Session 8 phase B2: the abuse queue, the Stripe inbox and adoption,
        # the scheduler and the platform settings. Same gate, same reasoning —
        # none of them acts on the acting user's own account.
        'operator/abuse_flags#resolve' => 'require_operator_access!',
        'operator/abuse_flags#resume_sending' => 'require_operator_access!',
        'operator/billing#retry_event' => 'require_operator_access!',
        'operator/billing#adopt' => 'require_operator_access!',
        'operator/scheduler#run_now' => 'require_operator_access!',
        'operator/settings#update' => 'require_operator_access!',
        # Session 8 phase C: starting and ending a support session. Both act on
        # an account the OPERATOR picked and both are behind the same gate.
        'operator/impersonations#create' => 'require_operator_access!',
        'operator/impersonations#destroy' => 'require_operator_access!'
      }
    end

    # Everything else: a write on the account, refused while it is frozen.
    let(:refused_while_suspended) do
      %w[
        accounts#update
        account_configs#create account_configs#destroy account_custom_fields#create
        account_invites#create account_invites#destroy account_invites#resend
        api_settings#create
        email_smtp_settings#create email_smtp_settings#destroy
        mcp_settings#create mcp_settings#destroy
        notifications_settings#create
        personalization_settings#create personalization_logo#create personalization_logo#destroy
        submissions#create submissions#destroy submissions_resend_email#create submissions_unarchive#create
        submitters#update submitters_resubmit#update submitters_send_email#create
        template_documents#create template_folders#update template_folders#destroy
        template_sharings_testing#create
        templates#create templates#update templates#destroy
        templates_clone#create templates_clone_and_replace#create templates_detect_fields#create
        templates_folders#update templates_preferences#create templates_preferences#destroy
        templates_prefillable_fields#create templates_recipients#create templates_restore#create
        templates_share_link#create templates_uploads#create templates_versions#create
        testing_accounts#create testing_accounts#destroy
        users#create users#update users#destroy
        users_read_only#create users_read_only#destroy users_send_reset_password#update
        webhook_events#refresh webhook_events#resend
        webhook_preferences#update webhook_secret#update
        webhook_settings#create webhook_settings#update webhook_settings#destroy webhook_settings#resend
      ]
    end

    # The signer's own doors, the public pages, the sign-in machinery and the
    # machine APIs. None of them is an account administrator writing to their
    # own account: the signer doors are asserted in the groups above and the
    # token doors in spec/golden/token_account_state_spec.rb.
    let(:not_the_authenticated_app) do
      %w[start_form start_form_email_2fa_send submit_form submit_form_decline submit_form_delegate
         submit_form_invite submit_form_email_2fas send_submission_email verify reports
         sessions registrations passwords confirmations omniauth_callbacks invitations
         stripe_webhooks postmark_webhooks invites mcp setup embed_template_builder
         active_storage/direct_uploads active_storage/disk]
    end

    def write_actions
      Rails.application.routes.routes.filter_map do |route|
        controller = route.defaults[:controller].to_s

        next if controller.blank?
        next unless route.verb.to_s.match?(/POST|PUT|PATCH|DELETE/)
        next if controller.start_with?('api/')
        next if not_the_authenticated_app.include?(controller)

        "#{controller}##{route.defaults[:action]}"
      end.uniq
    end

    it 'classifies every write route of the authenticated app, so a new one has to be decided about' do
      expect(write_actions).to match_array(
        allowed_while_suspended.keys + operator_only.keys + refused_while_suspended
      )
    end

    # Driven for real: every account-level and seat-level door, which is where
    # this session's changes live. The document doors (templates, submissions,
    # submitters, folders) share one CanCan rule and are asserted by the
    # examples at the top of this file.
    it 'refuses every account and seat door that is not on the allowed list' do
      webhook = create(:webhook_url, account:)
      config = create(:encrypted_config, account:, key: EncryptedConfig::ESIGN_CERTS_KEY, value: { 'cert' => 'x' })
      create(:account_config, account:, key: AccountConfig::ENABLE_MCP_KEY, value: true)
      token = admin.mcp_tokens.create!(name: 'Before')
      member = create(:user, account:, role: User::EDITOR_ROLE)
      invite = create(:account_invite, account:)
      signed_submitter = send_one.submitters.first
      event = WebhookEvent.create!(account:, webhook_url: webhook, uuid: SecureRandom.uuid,
                                   event_type: 'form.completed', record_type: 'Submitter',
                                   record_id: signed_submitter.id, status: 'error')

      suspend!
      act_as(admin)

      refused = {
        [:patch, '/settings/account'] => { account: { name: 'Renamed while suspended' } },
        [:post, '/account_configs'] => {
          account_config: { key: AccountConfig::ALLOW_TO_DECLINE_KEY, value: 'true' }
        },
        [:post, '/account_custom_fields'] => { name: 'While suspended' },
        [:post, '/settings/api'] => {},
        [:post, '/settings/email'] => { encrypted_config: { value: { 'host' => 'smtp.example.com' } } },
        [:post, '/settings/mcp'] => { mcp_token: { name: 'While suspended' } },
        [:delete, "/settings/mcp/#{token.id}"] => {},
        [:post, '/settings/notifications'] => {
          account_config: { key: AccountConfig::BCC_EMAILS, value: 'a@example.com' }
        },
        [:post, '/settings/personalization'] => {
          account_config: { key: AccountConfig::FORM_COMPLETED_MESSAGE_KEY, value: { 'body' => 'While suspended' } }
        },
        [:post, '/settings/personalization_logo'] => {},
        [:delete, '/settings/personalization_logo'] => {},
        [:post, '/settings/webhooks'] => { webhook_url: { url: 'https://example.com/new' } },
        [:patch, "/settings/webhooks/#{webhook.id}"] => { webhook_url: { url: 'https://example.com/changed' } },
        [:delete, "/settings/webhooks/#{webhook.id}"] => {},
        [:post, "/settings/webhooks/#{webhook.id}/resend"] => {},
        [:post, "/settings/webhooks/#{webhook.id}/events/#{event.id}/resend"] => {},
        [:post, "/settings/webhooks/#{webhook.id}/events/#{event.id}/refresh"] => {},
        [:put, "/webhook_secret/#{webhook.id}"] => {
          webhook_url: { secret: { 'X-Token' => 'while-suspended' } }
        },
        [:put, "/webhook_preferences/#{webhook.id}"] => { webhook_url: { events: %w[form.completed] } },
        [:post, '/users'] => { user: { email: 'while-suspended@example.com', role: 'admin' } },
        [:put, "/users/#{member.id}"] => { user: { first_name: 'Changed' } },
        [:delete, "/users/#{member.id}"] => {},
        [:post, "/users/#{member.id}/read_only"] => {},
        [:delete, "/users/#{member.id}/read_only"] => {},
        [:put, "/users/#{member.id}/send_reset_password"] => {},
        [:post, '/account_invites'] => { offer: 'anything' },
        [:post, "/account_invites/#{invite.id}/resend"] => {},
        [:delete, "/account_invites/#{invite.id}"] => {},
        [:post, '/testing_account'] => {},
        [:delete, '/testing_account'] => {},
        [:post, '/template_sharings_testing'] => { template_id: template.id, value: '1' },
        # Both of these are the ACCOUNT writing, not a signer: one re-sends
        # the invitation email, the other reopens a completed submitter.
        [:post, "/submitters/#{signed_submitter.id}/send_email"] => {},
        [:put, "/submitters_resubmit/#{signed_submitter.id}"] => {}
      }

      refused.each do |(verb, path), params|
        public_send(verb, path, params:)

        expect(response).to have_http_status(:redirect), "#{verb.upcase} #{path} was not refused"
        expect(flash[:alert]).to be_present, "#{verb.upcase} #{path} was refused without saying why"
      end

      # Nothing moved.
      expect(account.reload.name).not_to eq('Renamed while suspended')
      expect(account.archived_at).to be_nil
      expect(webhook.reload.url).not_to eq('https://example.com/changed')
      expect(WebhookUrl.where(account:).count).to eq(1)
      expect(config.reload.value).to eq('cert' => 'x')
      expect(McpToken.where(user: admin).count).to eq(1)
      expect(member.reload.first_name).not_to eq('Changed')
      expect(member.archived_at).to be_nil
      expect(member.read_only_at).to be_nil
      expect(User.find_by(email: 'while-suspended@example.com')).to be_nil
      expect(AccountInvite.where(account:).count).to eq(1)
      expect(invite.reload.revoked_at).to be_nil
      expect(account.testing_accounts).to be_empty
      expect(TemplateSharing.count).to eq(0)
    end

    # The claim on the allowed list above, driven for real: a customer whose
    # card kept failing must be able to LEAVE. Requesting deletion is the one
    # write on the account row the frozen state keeps open, and cancelling it
    # again is the other — being unable to change your mind would be a worse
    # trap than the one this whole layer exists to avoid.
    it 'lets a suspended admin ask for deletion and then change their mind' do
      suspend!
      act_as(admin)

      delete '/settings/account', params: { password: 'password', confirm: '1' }

      expect(response).to redirect_to(settings_account_path)
      expect(account.reload.deletion_requested_at).to be_present
      expect(account.purge_scheduled_for).to be_present
      expect(account.suspension_reason).to eq('deletion')

      post '/settings/account/cancel_deletion'

      expect(account.reload.deletion_requested_at).to be_nil
      expect(account.purge_scheduled_for).to be_nil
    end

    # The two doors this account still needs, and the one thing it may still
    # change about itself.
    it 'leaves the billing doors and their own profile open' do
      suspend!
      act_as(admin)

      get '/settings/billing'

      expect(response).to have_http_status(:ok)

      patch '/settings/profile/update_contact', params: { user: { first_name: 'Still', last_name: 'Here' } }

      expect(admin.reload.first_name).to eq('Still')

      # And the pages that only LOOK at the account stay readable.
      get '/settings/users'

      expect(response).to have_http_status(:ok)

      get '/settings/account'

      expect(response).to have_http_status(:ok)
    end
  end

  # Review batch 1 loop 2, G1: "read-only" is two different situations wearing
  # one layer, and the account row is where they part company.
  #
  #   * an account frozen for a failed payment puts EVERY member in the layer,
  #     its viewers and editors included — and `:billing` in their hands is the
  #     Customer Portal, where anybody could cancel the company's subscription;
  #   * a member parked read-only by a downgrade is in the same layer on a
  #     perfectly healthy PAYING account, and must not reach the money either.
  #
  # So the account abilities come back for an administrator who still holds a
  # seat, and for nobody else.
  describe 'who may reach the money and the people page' do
    include_context 'with a Stripe test account'

    let(:paid_account) { create(:account, :paid, seats: 3) }
    let(:paid_admin) { create(:user, account: paid_account) }

    # The Customer Portal is the door this whole group is about: it is where a
    # subscription gets cancelled, and it is one POST away from anybody who
    # holds `:billing`.
    def stub_portal_session
      stub_request(:post, 'https://api.stripe.com/v1/billing_portal/sessions')
        .to_return(status: 200,
                   body: { id: 'bps_test', object: 'billing_portal.session',
                           url: 'https://billing.stripe.com/session/test' }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
    end

    def expect_refused(&)
      yield

      expect(response).to have_http_status(:redirect)
      expect(response).to redirect_to(root_path)
    end

    def expect_no_account_doors(user)
      act_as(user)

      expect_refused { get '/settings/billing' }
      expect_refused { post '/settings/billing/portal' }
      expect_refused { post '/settings/billing/checkout' }
      expect_refused { get '/settings/users' }
      expect_refused { post "/users/#{user.id}/read_only" }
      expect_refused { delete "/users/#{user.id}/read_only" }
    end

    it 'refuses the billing and people pages to a read-only viewer and editor of a suspended account' do
      viewer = create(:user, account:, role: User::VIEWER_ROLE)
      editor = create(:user, account:, role: User::EDITOR_ROLE)

      suspend!

      expect_no_account_doors(viewer.reload)
      expect_no_account_doors(editor.reload)
    end

    # A parked member is read-only on an account that is paying perfectly
    # well: nothing about the money is theirs to touch.
    it 'refuses them to a member parked read-only on a healthy paid account' do
      parked = create(:user, account: paid_account, read_only_at: Time.current)

      expect_no_account_doors(parked)
    end

    it 'refuses them to an ADMIN parked read-only, however healthy the account' do
      parked_admin = create(:user, account: paid_account, read_only_at: Time.current)

      expect(parked_admin).to be_admin

      expect_no_account_doors(parked_admin)
    end

    # The one person who must keep them: the administrator of an account
    # frozen for a failed payment. They can see the money and the people —
    # and they still cannot WRITE, including the seat button that would call
    # Stripe.
    it 'keeps them for a suspended administrator, who still writes nothing' do
      member = create(:user, account:, role: User::EDITOR_ROLE)
      account.account_subscription.update!(
        access_state: 'past_due', status: 'past_due', stripe_status: 'past_due',
        stripe_customer_id: customer_a, stripe_subscription_id: subscription_a
      )
      stub_portal_session

      suspend!
      act_as(admin)

      get '/settings/billing'

      expect(response).to have_http_status(:ok)

      # The one door that fixes it: Stripe's own portal, where the card gets
      # replaced. A suspended admin must be able to reach it.
      post '/settings/billing/portal'

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to('https://billing.stripe.com/session/test')

      get '/settings/users'

      expect(response).to have_http_status(:ok)

      # No Stripe stub anywhere in this example: a seat release from here
      # would be an unstubbed call and this would fail.
      expect { post "/users/#{member.id}/read_only" }.not_to(change { member.reload.read_only_at })

      expect(flash[:alert]).to eq(I18n.t('account_suspended_alert'))

      expect { delete "/users/#{admin.id}/read_only" }.not_to(change { admin.reload.read_only_at })

      expect(flash[:alert]).to eq(I18n.t('account_suspended_alert'))
    end

    it 'leaves a healthy paying administrator every door they had' do
      act_as(paid_admin)

      get '/settings/billing'

      expect(response).to have_http_status(:ok)

      get '/settings/users'

      expect(response).to have_http_status(:ok)

      member = create(:user, account: paid_account, role: User::EDITOR_ROLE)

      expect { post "/users/#{member.id}/read_only" }.to(change { member.reload.read_only_at }.from(nil))
    end
  end

  describe Ability do
    let(:other_user) { create(:user, account:) }

    it 'takes away every write and leaves every read, plus the user\'s own profile' do
      suspend!
      ability = described_class.new(admin.reload)

      expect(ability.can?(:create, Template.new(account:))).to be(false)
      expect(ability.can?(:update, template)).to be(false)
      expect(ability.can?(:destroy, template)).to be(false)
      expect(ability.can?(:create, Submission.new(account:))).to be(false)
      expect(ability.can?(:update, other_user)).to be(false)
      expect(ability.can?(:manage, :mcp)).to be(false)

      expect(ability.can?(:read, template)).to be(true)
      expect(ability.can?(:read, Submission.new(account:))).to be(true)
      expect(ability.can?(:update, admin)).to be(true)

      # Review batch 1, F3 changed this: `:manage` on the account used to be
      # left in place so the billing page could authorize it, and it carried
      # renaming the account, deleting it and uploading a logo along with it.
      # The billing page now authorizes `:billing`, which is all it ever
      # needed, and reading the settings pages is `:read`.
      expect(ability.can?(:billing, account)).to be(true)
      expect(ability.can?(:read, account)).to be(true)
      expect(ability.can?(:manage, account)).to be(false)
      expect(ability.can?(:update, account)).to be(false)
      expect(ability.can?(:destroy, account)).to be(false)
      expect(ability.can?(:create, AccountInvite.new(account:))).to be(false)
      expect(ability.can?(:manage, TemplateSharing.new(template:))).to be(false)
      expect(ability.can?(:read, TemplateSharing.new(template:))).to be(true)
      expect(ability.can?(:resend, WebhookUrl.new(account:))).to be(false)
    end

    it 'leaves an active account\'s abilities exactly as they were' do
      ability = described_class.new(admin)

      expect(ability.can?(:create, Template.new(account:))).to be(true)
      expect(ability.can?(:update, other_user)).to be(true)
    end

    # A linked child is paid for by its parent: when the parent stops paying,
    # the child stops writing too.
    it 'freezes a child account whose parent is suspended' do
      child = create(:account, linked_account_account: AccountLinkedAccount.new(account_type: :linked, account:))
      child_admin = create(:user, account: child)

      expect(described_class.new(child_admin).can?(:create, Template.new(account: child))).to be(true)

      suspend!

      expect(AccountStates.read_only?(child.reload)).to be(true)
      expect(described_class.new(child_admin).can?(:create, Template.new(account: child))).to be(false)
    end
  end
end

# The clock itself: how a failed payment turns into reminders, then a
# suspension, and how paying undoes it. Nothing here calls Stripe — the
# captures go straight into the one mapping every Stripe door shares.
RSpec.describe 'Billing dunning', type: :request do
  let(:account) { create(:account) }
  let!(:admin) { create(:user, account:) }
  let(:deliveries) { ActionMailer::Base.deliveries }
  let(:fixture_price) { 'price_1UAt8N4rEeOqtLcX1amJxYdZ' }
  # The five subjects the dunning clock can send, spelled once.
  let(:first_notice) { 'We could not take your EsignCenter payment' }
  let(:reminder) { 'Your EsignCenter payment is still outstanding' }
  let(:last_warning) { 'Last reminder: your EsignCenter account is suspended tomorrow' }
  # The catch-up copy of the same letter, sent in the tick that suspends.
  let(:late_warning) { 'Last reminder: your EsignCenter payment is overdue' }
  let(:suspended_subject) { 'Your EsignCenter account is suspended' }
  let(:recovered) { 'Your EsignCenter payment went through' }
  let(:subscription) do
    create(:account_subscription, account:, access_state: 'active', status: 'active',
                                  stripe_customer_id: 'cus_VBqKHh0NHYmvT1',
                                  stripe_subscription_id: 'sub_1UBSds4rEeOqtLcXs81X4tCG')
  end

  stash_env('STRIPE_PRICE_ID')

  before do
    ENV['STRIPE_PRICE_ID'] = fixture_price
    deliveries.clear
  end

  # A real CLI capture, with only `status` changed where a state the CLI
  # cannot easily produce is needed (the same licence stripe_spec takes).
  def apply!(fixture, status: nil)
    body = JSON.parse(Rails.root.join("spec/fixtures/stripe/#{fixture}.json").read)
    body['status'] = status if status

    StripeBilling::SubscriptionSync.apply!(subscription, body)

    subscription.reload
  end

  # Matched on the WHOLE subject: 'Last reminder: … account is suspended
  # tomorrow' and 'Your … account is suspended' share a fragment, and a
  # fragment match would count the warning as the suspension notice.
  def mails_titled(subject)
    deliveries.select { |mail| mail.subject.to_s == subject }
  end

  # The mail is multipart by the time the interceptor is done, so the HTML
  # part is where the words are.
  def body_of(mail)
    (mail.html_part || mail.text_part || mail.body).decoded
  end

  it 'stamps the clock, mails day 0 once, and says nothing on a repeat of the same state', sidekiq: :inline do
    apply!('subscription-past_due')

    expect(subscription.access_state).to eq('past_due')
    expect(subscription.past_due_since).to be_present
    expect(mails_titled(first_notice).size).to eq(1)
    expect(mails_titled(first_notice).sole.to).to eq([admin.email])
    expect(body_of(mails_titled(first_notice).sole))
      .to include((subscription.past_due_since + 14.days).utc.strftime('%-d %B %Y'))

    stamped = subscription.past_due_since

    apply!('subscription-past_due')

    expect(subscription.past_due_since).to eq(stamped)
    expect(mails_titled(first_notice).size).to eq(1)
  end

  it 'mails on days 3, 7 and 13, once each, then suspends on day 14 and mails that', sidekiq: :inline do
    apply!('subscription-past_due')
    started = subscription.past_due_since

    [3, 7, 13].each do |day|
      travel_to(started + day.days + 1.hour) do
        2.times { BillingLifecycle.run_dunning! }
      end
    end

    expect(mails_titled(reminder).size).to eq(2)
    expect(mails_titled(last_warning).size).to eq(1)
    expect(account.reload.suspended_at).to be_nil

    travel_to(started + 14.days + 1.hour) do
      2.times { BillingLifecycle.run_dunning! }
    end

    expect(account.reload.suspended_at).to be_present
    expect(account.suspension_reason).to eq('billing')
    expect(mails_titled(suspended_subject).size).to eq(1)
    expect(AccountStates.read_only?(account)).to be(true)
  end

  # The catch-up tick sends the final reminder and the suspension notice
  # together, so the reminder may not talk about the freeze as something that
  # is still coming: its ordinary wording promises "on <date> the account is
  # suspended" and "nothing has changed on your account yet", and by the time
  # this copy lands both sentences are false. The late letter says the
  # account was suspended today, and its subject drops "tomorrow".
  it 'catches up a missed final reminder at day 15 and suspends, each mail exactly once', sidekiq: :inline do
    subscription.update!(access_state: 'past_due', past_due_since: 15.days.ago)

    # Delivered mail is the proof (a method spy would count the inline
    # delivery job's own call to the mailer as a second send).
    2.times { BillingLifecycle.run_dunning! }

    expect(account.reload.suspended_at).to be_present
    expect(account.suspension_reason).to eq('billing')
    expect(mails_titled(late_warning).size).to eq(1)
    expect(mails_titled(last_warning)).to be_empty
    expect(mails_titled(suspended_subject).size).to eq(1)
    expect(mails_titled(first_notice)).to be_empty
    expect(mails_titled(reminder)).to be_empty

    body = body_of(mails_titled(late_warning).sole)

    expect(body).to include('the account was suspended today')
    expect(body).not_to include('Nothing has changed on your account yet')
    expect(body).not_to include('the account is suspended. A suspended account')
  end

  # And the reminder that arrives ON day 13, a day before the deadline, still
  # says the freeze is ahead of it — the late wording is for the late tick
  # only.
  it 'keeps the future tense on a day-13 reminder sent inside the grace period', sidekiq: :inline do
    apply!('subscription-past_due')
    started = subscription.past_due_since

    travel_to(started + 13.days + 1.hour) { BillingLifecycle.run_dunning! }

    expect(mails_titled(late_warning)).to be_empty
    expect(account.reload.suspended_at).to be_nil

    body = body_of(mails_titled(last_warning).sole)

    expect(body).to include('Nothing has changed on your account yet')
    expect(body).to include((started + 14.days).utc.strftime('%-d %B %Y'))
    expect(body).not_to include('was suspended today')
  end

  # Review 7, A4. The dedupe counter used to be spent BEFORE the mail was
  # handed over, so a queue that was down for one hourly tick ate that day's
  # reminder for good. On day 13 — the last word before the account is frozen
  # — that is the difference between a suspension somebody saw coming and one
  # that arrives out of nowhere.
  it 'does not spend the last warning on a delivery that failed', sidekiq: :inline do
    apply!('subscription-past_due')
    started = subscription.past_due_since

    travel_to(started + 7.days + 1.hour) { BillingLifecycle.run_dunning! }

    expect(mails_titled(reminder).size).to eq(2)

    # The queue is down on the day-13 tick, and only on that tick.
    broken = instance_double(ActionMailer::MessageDelivery)
    allow(broken).to receive(:deliver_later!).and_raise('the mail queue is down')
    allow(BillingMailer).to receive(:payment_failed).and_wrap_original do |original, *args, **kwargs|
      kwargs[:day] == 13 ? broken : original.call(*args, **kwargs)
    end

    travel_to(started + 13.days + 1.hour) { BillingLifecycle.run_dunning! }

    expect(mails_titled(last_warning)).to be_empty
    expect(AccountCounters.value(account.id, "dunning:#{started.to_i}:day13",
                                 period: BillingLifecycle::COUNTER_PERIOD)).to eq(0)

    # The queue comes back and the very next tick sends it, because the day
    # was never marked done.
    allow(BillingMailer).to receive(:payment_failed).and_call_original

    travel_to(started + 13.days + 2.hours) { BillingLifecycle.run_dunning! }

    expect(mails_titled(last_warning).size).to eq(1)

    # And still exactly once, however many ticks follow.
    travel_to(started + 13.days + 3.hours) { 2.times { BillingLifecycle.run_dunning! } }

    expect(mails_titled(last_warning).size).to eq(1)
    expect(account.reload.suspended_at).to be_nil
  end

  it 'lifts the suspension and says so once when the payment goes through', sidekiq: :inline do
    apply!('subscription-past_due')
    started = subscription.past_due_since

    travel_to(started + 14.days + 1.hour) { BillingLifecycle.run_dunning! }

    expect(account.reload.suspended_at).to be_present

    apply!('subscription-active-recovered')

    expect(subscription.access_state).to eq('active')
    expect(subscription.past_due_since).to be_nil
    expect(account.reload.suspended_at).to be_nil
    expect(account.suspension_reason).to be_nil
    expect(mails_titled(recovered).size).to eq(1)
    expect(body_of(mails_titled(recovered).sole)).to include('The freeze on your account has been lifted')

    apply!('subscription-active-recovered')

    expect(mails_titled(recovered).size).to eq(1)
  end

  # Checkpoint 7, Q3. The same letter goes out when the payment is caught
  # before day 14, and it used to say "Nothing on the account was ever frozen"
  # — which is a claim about the whole history of the account and is simply
  # false for anybody we suspended in an earlier cycle. The letter now says
  # only what this recovery knows: it was not frozen THIS time.
  it 'tells a customer who paid in time that nothing was frozen this time, not ever', sidekiq: :inline do
    # An earlier cycle really did freeze this account, and it was paid off.
    apply!('subscription-past_due')
    started = subscription.past_due_since

    travel_to(started + 14.days + 1.hour) { BillingLifecycle.run_dunning! }

    expect(account.reload.suspended_at).to be_present

    apply!('subscription-active-recovered')
    deliveries.clear

    # A later cycle: the card fails again and is paid before the fortnight is
    # up, so there is no freeze to lift this time.
    apply!('subscription-past_due')

    expect(account.reload.suspended_at).to be_nil

    apply!('subscription-active-recovered')

    body = body_of(mails_titled(recovered).sole)

    expect(body).to include('Your account was not frozen this time')
    expect(body).not_to include('ever frozen')
    expect(body).not_to include('has been lifted')
  end

  # Stripe says `unpaid` when it gives up on the card. There is no grace left
  # to give at that point, so the account is suspended at once.
  it 'suspends immediately when Stripe gives up on the card', sidekiq: :inline do
    apply!('subscription-past_due', status: 'unpaid')

    expect(subscription.access_state).to eq('suspended')
    expect(account.reload.suspended_at).to be_present
    expect(account.suspension_reason).to eq('billing')
    expect(mails_titled(suspended_subject).size).to eq(1)
  end

  # Review-6 C7: a past_due → unpaid → past_due wobble must not hand the
  # customer a fresh 14 days each time round.
  it 'keeps the original clock through unpaid and back again', sidekiq: :inline do
    apply!('subscription-past_due')
    started = subscription.past_due_since

    apply!('subscription-past_due', status: 'unpaid')

    expect(subscription.access_state).to eq('suspended')
    expect(subscription.past_due_since).to eq(started)

    apply!('subscription-past_due')

    expect(subscription.access_state).to eq('past_due')
    expect(subscription.past_due_since).to eq(started)

    # Still inside the 14 days, so the account is back to normal — but the
    # deadline is the original one, not a new one.
    expect(account.reload.suspended_at).to be_nil
    expect(BillingLifecycle.suspends_on(subscription)).to eq(started + 14.days)
  end

  # Review batch 1, F1: Stripe gives up on an unpaid subscription about a week
  # after our own day-14 suspension and cancels it. Nothing lifted the
  # suspension on that path, so the account became a FREE account that was
  # frozen for writes forever — no payment left to make, and no door that
  # could ever unfreeze it.
  it 'lifts the suspension when the subscription finally ends, and says nothing about it', sidekiq: :inline do
    apply!('subscription-past_due')
    started = subscription.past_due_since

    travel_to(started + 14.days + 1.hour) { BillingLifecycle.run_dunning! }

    expect(account.reload.suspended_at).to be_present

    deliveries.clear

    apply!('subscription-canceled')

    expect(subscription.access_state).to eq('cancelled')
    expect(account.reload.suspended_at).to be_nil
    expect(AccountStates.read_only?(account)).to be(false)
    expect(Plans.key_for(account)).to eq(Plans::FREE)

    # It is not a recovery: nobody paid, the subscription is simply over.
    expect(mails_titled(recovered)).to be_empty
  end

  # F1, the other half: the state is what decides whether the account can work
  # at all, so it moves FIRST and nothing after it can swallow it. The seat
  # step used to run before it, and anything that threw in there — a mailer, a
  # lock — took the whole state change down with it.
  it 'moves the state before anything else, so a later step blowing up cannot swallow it', sidekiq: :inline do
    create_list(:user, 2, account:)
    apply!('subscription-past_due')
    started = subscription.past_due_since

    travel_to(started + 14.days + 1.hour) { BillingLifecycle.run_dunning! }

    expect(account.reload.suspended_at).to be_present

    # The subscription ends, which lifts the suspension AND leaves more people
    # than the free plan holds — and the mail about that second half fails.
    allow(BillingMailer).to receive(:seats_reduced).and_raise(StandardError, 'mail server on fire')

    apply!('subscription-canceled')

    expect(account.reload.suspended_at).to be_nil
    expect(AccountStates.read_only?(account)).to be(false)
    # The step that threw had already done its work, and it stands too.
    expect(User.where(account:).read_only.count).to eq(2)
  end

  it 'suspends even when the suspension mail cannot be sent', sidekiq: :inline do
    allow(BillingMailer).to receive(:suspended).and_raise(StandardError, 'mail server on fire')

    apply!('subscription-past_due', status: 'unpaid')

    expect(subscription.access_state).to eq('suspended')
    expect(account.reload.suspended_at).to be_present
  end

  # F9: unpaid, back inside the grace window, then unpaid again is two honest
  # suspensions on ONE dunning clock, and the customer heard about it twice.
  it 'says the account is suspended once per clock, however Stripe wobbles', sidekiq: :inline do
    apply!('subscription-past_due')
    apply!('subscription-past_due', status: 'unpaid')

    expect(account.reload.suspended_at).to be_present
    expect(mails_titled(suspended_subject).size).to eq(1)

    # Back inside the 14 days: the suspension lifts...
    apply!('subscription-past_due')

    expect(account.reload.suspended_at).to be_nil

    # ...and straight back out again. Same clock, same suspension, one email.
    apply!('subscription-past_due', status: 'unpaid')

    expect(account.reload.suspended_at).to be_present
    expect(mails_titled(suspended_subject).size).to eq(1)
  end

  # Review batch 1 loop 2, G4: `suspend!` answers false for three different
  # reasons, and only one of them is "already said". Sending the billing
  # suspension email when an OPERATOR's suspension is what is actually in
  # place tells the customer their card failed when it did not — and spends
  # the once-per-clock counter, so the real notice would never be sent.
  it 'never announces a billing suspension that is really somebody else\'s', sidekiq: :inline do
    AccountStates.suspend!(account, reason: 'operator')
    deliveries.clear

    apply!('subscription-past_due', status: 'unpaid')

    expect(account.reload.suspension_reason).to eq('operator')
    expect(mails_titled(suspended_subject)).to be_empty

    # And the counter was not spent on it: once the operator lifts theirs, the
    # billing suspension still gets to say what it is.
    AccountStates.lift_suspension!(account, reason: 'operator')

    apply!('subscription-past_due', status: 'unpaid')

    expect(account.reload.suspension_reason).to eq('billing')
    expect(mails_titled(suspended_subject).size).to eq(1)
  end

  # H2: `suspend!` can fail part-way and leave the object in hand carrying
  # values that were never written. Announcing a suspension that does not
  # exist is worse than saying nothing — and spending the once-per-clock
  # counter on it would silence the real notice for good.
  it 'says nothing, and spends nothing, when the suspension could not be written', sidekiq: :inline do
    apply!('subscription-past_due')
    deliveries.clear

    allow_any_instance_of(Account).to receive(:update!).and_raise(ActiveRecord::StatementInvalid, 'no write')

    apply!('subscription-past_due', status: 'unpaid')

    expect(account.reload.suspended_at).to be_nil
    expect(mails_titled(suspended_subject)).to be_empty

    # The counter was not spent: once the write works, the notice goes out.
    allow_any_instance_of(Account).to receive(:update!).and_call_original

    apply!('subscription-past_due', status: 'unpaid')

    expect(account.reload.suspended_at).to be_present
    expect(mails_titled(suspended_subject).size).to eq(1)
  end

  it 'never lets a payment undo an operator suspension', sidekiq: :inline do
    apply!('subscription-past_due')
    started = subscription.past_due_since

    travel_to(started + 14.days + 1.hour) { BillingLifecycle.run_dunning! }

    # The operator takes the decision over: the billing recovery below must
    # not be what lifts it.
    account.reload.update!(suspension_reason: 'operator')

    apply!('subscription-active-recovered')

    expect(account.reload.suspended_at).to be_present
    expect(account.suspension_reason).to eq('operator')
    expect(AccountStates.read_only?(account)).to be(true)
    expect(AccountStates.lift_suspension!(account, reason: 'billing')).to be(false)
  end

  it 'never suspends an internal account through the dunning sweep', sidekiq: :inline do
    internal = create(:account, :internal)
    create(:user, account: internal)
    create(:account_subscription, account: internal, access_state: 'past_due', status: 'past_due',
                                  past_due_since: 30.days.ago)

    BillingLifecycle.run_dunning!

    expect(internal.reload.suspended_at).to be_nil
    expect(deliveries).to be_empty
  end

  it 'names the days that are due and nothing else' do
    row = AccountSubscription.new(past_due_since: nil)

    expect(BillingLifecycle.dunning_step_for(row, now: Time.current)).to eq([])
    expect(BillingLifecycle.suspends_on(row)).to be_nil

    row.past_due_since = Time.current

    expect(BillingLifecycle.dunning_step_for(row, now: Time.current)).to eq([0])
    expect(BillingLifecycle.dunning_step_for(row, now: 8.days.from_now)).to eq([0, 3, 7])
    expect(BillingLifecycle.dunning_step_for(row, now: 20.days.from_now)).to eq([0, 3, 7, 13])
  end
end
