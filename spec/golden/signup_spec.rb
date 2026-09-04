# frozen_string_literal: true

# Self-serve registration exists only behind REGISTRATION_ENABLED, creates
# exactly one customer account with an unconfirmed admin who cannot sign in
# until confirmed, and is protected by Turnstile, a disposable-email blocklist
# and per-IP limits; Google sign-up creates a confirmed user and never a
# duplicate.
RSpec.describe 'Self-serve registration', type: :request do
  stash_env 'REGISTRATION_ENABLED', 'TURNSTILE_SITE_KEY', 'TURNSTILE_SECRET_KEY',
            'GOOGLE_OAUTH_CLIENT_ID', 'GOOGLE_OAUTH_CLIENT_SECRET', clear: true

  let(:google_button) { I18n.t('continue_with_google') }

  # The instance is set up (the operator exists), so /sign_up is never the
  # first-run setup redirect.
  before do
    create(:user, account: create(:account, :operator))
    RateLimit.store.clear
  end

  after do
    RateLimit.store.clear
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end

  def enable_registration!
    ENV['REGISTRATION_ENABLED'] = 'true'
    ENV['TURNSTILE_SITE_KEY'] = 'turnstile-site-key'
    ENV['TURNSTILE_SECRET_KEY'] = 'turnstile-secret-key'
  end

  def enable_google!
    ENV['GOOGLE_OAUTH_CLIENT_ID'] = 'google-client-id'
    ENV['GOOGLE_OAUTH_CLIENT_SECRET'] = 'google-client-secret'
  end

  def signup_params(email: 'ada@example.com', name: 'Ada Lovelace', password: 'a-long-password',
                    token: 'turnstile-token', timezone: 'Europe/Paris')
    { user: { name:, email:, password:, timezone: }, 'cf-turnstile-response' => token }
  end

  def sign_up(**)
    post registration_path, params: signup_params(**)
  end

  def mock_google(email:, verified: true, name: 'Grace Hopper')
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] =
      OmniAuth::AuthHash.new(provider: 'google_oauth2', uid: '10769150350006150715113082367',
                             info: { email:, name: }, extra: { raw_info: { email_verified: verified } })
  end

  # The real flow: the POST-only authorize endpoint (OmniAuth's request
  # phase) redirects to the callback, which is where the controller runs.
  def sign_in_with_google!(**query)
    post user_google_oauth2_omniauth_authorize_path(query)

    expect(response).to have_http_status(:redirect)
    expect(response.location).to include(user_google_oauth2_omniauth_callback_path)

    follow_redirect!
  end

  # OmniAuth's own request phase, with the mock switched off just long enough
  # for the strategy to mint a real `state` and store it in this session (it
  # only builds Google's authorize URL — nothing goes out). Returns that
  # state: the one thing a callback must carry to reach the token exchange.
  def start_google_flow!
    OmniAuth.config.test_mode = false

    post user_google_oauth2_omniauth_authorize_path

    expect(response).to have_http_status(:redirect)

    CGI.parse(URI.parse(response.location).query)['state'].sole
  ensure
    OmniAuth.config.test_mode = true
  end

  # The root serves a landing page to visitors, so the probe is a page only
  # a signed-in user can open.
  def expect_signed_in
    get settings_profile_index_path

    expect(response).to have_http_status(:ok)
  end

  def expect_signed_out
    get settings_profile_index_path

    expect(response).to redirect_to(new_user_session_path)
  end

  def signed_up_user(email = 'ada@example.com')
    User.find_by!(email:)
  end

  describe 'the REGISTRATION_ENABLED switch' do
    it 'answers 404 on every sign-up surface and offers no link or button while off' do
      enable_google!

      expect { sign_up }.not_to change(Account, :count)
      expect(response).to have_http_status(:not_found)

      get new_registration_path
      expect(response).to have_http_status(:not_found)

      get confirm_registration_path
      expect(response).to have_http_status(:not_found)

      post user_google_oauth2_omniauth_authorize_path
      expect(response).to have_http_status(:not_found)

      get user_google_oauth2_omniauth_callback_path
      expect(response).to have_http_status(:not_found)

      get new_user_session_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(google_button)
      expect(response.body).not_to include(new_registration_path)
      expect(response.body).not_to include(I18n.t('create_free_account'))
      expect(User.count).to eq(1)
    end

    it 'serves the sign-up page, the link and the Google button while on' do
      enable_registration!
      enable_google!

      get new_registration_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('cf-turnstile')
      expect(response.body).to include('data-sitekey="turnstile-site-key"')
      expect(response.body).to include(google_button)
      expect(response.body).to include(I18n.t('free_tier_summary'))

      get new_user_session_path
      expect(response.body).to include(google_button)
      expect(response.body).to include(new_registration_path)
    end
  end

  describe 'email and password sign-up' do
    it 'creates one customer account with an unconfirmed admin who signs in only after confirming' do
      enable_registration!
      stub_turnstile(success: true)
      mail_account_header = nil
      allow(ActionMailerConfigsInterceptor).to receive(:delivering_email).and_wrap_original do |original, message|
        mail_account_header = message['X-EC-Account-Id']&.value
        original.call(message)
      end

      expect do
        post registration_path, params: signup_params, headers: { 'HTTP_ACCEPT_LANGUAGE' => 'fr-FR,fr;q=0.9' }
      end.to change(Account, :count).by(1).and change(User, :count).by(1)

      expect(response).to redirect_to(confirm_registration_path)

      user = signed_up_user
      account = user.account
      expect(account).to have_attributes(account_kind: Account::CUSTOMER_KIND, name: 'Ada Lovelace',
                                         timezone: 'Paris', locale: 'fr-FR')
      expect(account.users.count).to eq(1)
      expect(user).to have_attributes(role: User::ADMIN_ROLE, first_name: 'Ada', last_name: 'Lovelace',
                                      confirmed_at: nil)
      expect(user.confirmation_token).to be_present

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq(['ada@example.com'])
      expect(mail.from).to eq(['noreply@esigncenter.com'])
      expect(mail.html_part.decoded).to include("confirmation_token=#{user.confirmation_token}")
      expect(mail.html_part.decoded).not_to include('DocuSeal')
      expect(mail_account_header).to eq(account.id.to_s)

      follow_redirect!
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('ada@example.com')
      expect(response.body).to include(new_user_confirmation_path)

      # The handoff's negative assertion: an unconfirmed user is not signed in.
      post user_session_path, params: { user: { email: 'ada@example.com', password: 'a-long-password' } }
      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('devise.failure.unconfirmed'))
      expect_signed_out

      get user_confirmation_path(confirmation_token: user.confirmation_token)
      expect(user.reload.confirmed_at).to be_present

      post user_session_path, params: { user: { email: 'ada@example.com', password: 'a-long-password' } }
      expect(response).to have_http_status(:redirect)
      expect_signed_in

      # The dashboard renders in the new account's own locale (fr-FR): a page
      # served for that account, not the visitor's landing page.
      get root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('lang="fr-FR"')
      expect(response.body).to include(new_template_path)
    end

    it 'refuses a failed Turnstile check, a blank token and an outage, writing nothing' do
      enable_registration!
      stub_turnstile(success: false, error_codes: ['invalid-input-response'])

      expect { sign_up }.not_to change(User, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('please_complete_the_verification'))
      expect(ActionMailer::Base.deliveries).to be_empty

      stub_turnstile(success: true)
      WebMock.reset_executed_requests!

      expect { sign_up(token: '') }.not_to change(User, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(a_request(:post, Turnstile::VERIFY_URL)).not_to have_been_made

      stub_turnstile_outage
      allow(ErrorReport).to receive(:warning)

      expect { sign_up }.not_to change(User, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(ErrorReport).to have_received(:warning).with(kind_of(Faraday::Error), remote_ip: '127.0.0.1')

      ENV.delete('TURNSTILE_SECRET_KEY')
      expect { sign_up }.not_to change(User, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(Account.count).to eq(1)
    end

    it 'refuses a disposable address at sign-up but not when an admin invites it' do
      enable_registration!
      stub_turnstile(success: true)

      expect { sign_up(email: 'throwaway@mailinator.com') }.not_to change(User, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('please_use_a_permanent_email_address'))
      expect(Account.count).to eq(1)

      admin = create(:user, account: create(:account, :internal))
      sign_in(admin)

      expect do
        post users_path, params: { user: { email: 'throwaway@mailinator.com', first_name: 'Temp',
                                           last_name: 'Box', role: User::ADMIN_ROLE } }
      end.to change(User, :count).by(1)
      expect(User.find_by(email: 'throwaway@mailinator.com').account).to eq(admin.account)
    end

    it 'refuses the sixth sign-up from one network within the hour and leaves invitations alone' do
      enable_registration!
      stub_turnstile(success: true)

      5.times do |i|
        sign_up(email: "person#{i}@example.com", name: "Person #{i}")
        expect(response).to redirect_to(confirm_registration_path)
      end

      expect { sign_up(email: 'sixth@example.com', name: 'Sixth Person') }.not_to change(User, :count)
      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include(I18n.t('too_many_sign_ups_from_this_network'))
      expect(Account.count).to eq(6)

      admin = create(:user, account: create(:account, :internal))
      sign_in(admin)

      expect do
        post users_path, params: { user: { email: 'invited@example.com', first_name: 'In', last_name: 'Vited',
                                           role: User::ADMIN_ROLE } }
      end.to change(User, :count).by(1)
    end

    # Devise's registerable reveals a taken address ("has already been
    # taken"); the paranoid setting covers confirmations and passwords, not
    # this form. Accepted: the alternative is a silent success that leaves a
    # real person waiting for mail that never comes.
    it 'refuses an address that already has a user, whatever its case, and never makes a second account' do
      enable_registration!
      stub_turnstile(success: true)
      create(:user, email: 'taken@example.com')

      expect { sign_up(email: 'Taken@Example.com') }.not_to change(Account, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('already been taken')
      expect(User.where('lower(email) = ?', 'taken@example.com').count).to eq(1)
    end

    it 'spends the per-network budget on sign-ups, not attempts: five failures never block the sixth person' do
      enable_registration!
      create(:user, email: 'taken@example.com')

      stub_turnstile(success: false, error_codes: ['invalid-input-response'])
      3.times do
        expect { sign_up(email: 'typo@example.com') }.not_to change(User, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      stub_turnstile(success: true)
      2.times do
        expect { sign_up(email: 'taken@example.com') }.not_to change(User, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('already been taken')
      end

      # Five failures spent nothing: the next five real sign-ups go through...
      Quotas::Limits::SIGNUPS_PER_IP_PER_HOUR.times do |i|
        expect { sign_up(email: "person#{i}@example.com", name: "Person #{i}") }.to change(User, :count).by(1)
        expect(response).to redirect_to(confirm_registration_path)
      end

      # ...and only then is the network's hour full.
      expect { sign_up(email: 'sixth@example.com', name: 'Sixth Person') }.not_to change(User, :count)
      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include(I18n.t('too_many_sign_ups_from_this_network'))
    end

    # The other per-network limit, and the reason it is checked first: the
    # Turnstile check is an outbound call with a five-second timeout, so an
    # attempt a stranger can replay for free is a web thread they can hold for
    # free. Past the ceiling nothing outbound happens at all, and the sign-up
    # budget — a separate counter, spent only on success — is untouched.
    it 'refuses attempts past the per-network ceiling without calling Cloudflare or spending the budget' do
      enable_registration!
      verification = stub_turnstile(success: true)
      Quotas::Limits::SIGNUP_ATTEMPTS_PER_IP_PER_HOUR.times { Registrations.assert_ip_attempt_allowed!('127.0.0.1') }

      expect { sign_up }.not_to change(User, :count)
      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include(I18n.t('too_many_sign_ups_from_this_network'))
      expect(verification).not_to have_been_requested

      expect { Quotas::Limits::SIGNUPS_PER_IP_PER_HOUR.times { Registrations.assert_ip_allowed!('127.0.0.1') } }
        .not_to raise_error
    end

    it 'tells the loser of two simultaneous sign-ups for one address that it is taken, without a 500' do
      enable_registration!
      stub_turnstile(success: true)
      allow(Registrations).to receive(:build_signup).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap do |user|
          allow(user).to receive(:save).and_raise(ActiveRecord::RecordNotUnique, 'duplicate key value')
        end
      end

      expect { sign_up(email: 'race@example.com') }.not_to change(Account, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('already been taken')
      expect(User.where(email: 'race@example.com')).not_to exist
    end
  end

  describe 'Google sign-up and sign-in' do
    before do
      enable_registration!
      enable_google!
    end

    it 'creates one customer account with a confirmed admin for a new verified address and signs them in' do
      mock_google(email: 'grace@example.com')

      expect { sign_in_with_google! }.to change(Account, :count).by(1).and change(User, :count).by(1)
      expect(response).to redirect_to(root_path)

      user = signed_up_user('grace@example.com')
      expect(user).to have_attributes(first_name: 'Grace', last_name: 'Hopper', role: User::ADMIN_ROLE)
      expect(user.confirmed_at).to be_present
      expect(user.account).to have_attributes(account_kind: Account::CUSTOMER_KIND, name: 'Grace Hopper')
      expect(ActionMailer::Base.deliveries).to be_empty
      expect_signed_in
    end

    it 'confirms an existing unconfirmed user and signs them in without a new account' do
      user = create(:user, email: 'pending@example.com', confirmed_at: nil)
      mock_google(email: 'pending@example.com')

      expect { sign_in_with_google! }.not_to change(Account, :count)
      expect(response).to redirect_to(root_path)
      expect(user.reload.confirmed_at).to be_present
      expect(User.where(email: 'pending@example.com').count).to eq(1)
      expect_signed_in
    end

    # The pre-hijack: anybody can type somebody else's address into the
    # sign-up form, and the unconfirmed row that writes carries the typist's
    # password. Confirming that row for the real owner without killing the
    # password would hand the typist a working sign-in at /sign_in to every
    # document the owner goes on to create.
    it 'kills the password on the unconfirmed row it adopts, so the stranger who typed the address cannot sign in' do
      stub_turnstile(success: true)
      post registration_path, params: signup_params(email: 'victim@example.com', name: 'Not The Owner',
                                                    password: 'stranger-password')
      expect(User.find_by(email: 'victim@example.com')).to be_present

      mock_google(email: 'victim@example.com')

      expect { sign_in_with_google! }.not_to change(User, :count)
      expect(response).to redirect_to(root_path)
      expect_signed_in

      delete destroy_user_session_path

      post user_session_path, params: { user: { email: 'victim@example.com', password: 'stranger-password' } }

      expect(response).not_to redirect_to(root_path)
      expect_signed_out
    end

    # The other side of that fix: a confirmed user proved the mailbox
    # themselves, so the password on their row is their own and Google
    # signing them in must not lock them out of it.
    it 'leaves a confirmed user their own password after they sign in with Google' do
      create(:user, email: 'both@example.com', password: 'their-own-password')
      mock_google(email: 'both@example.com')

      sign_in_with_google!
      expect(response).to redirect_to(root_path)
      expect_signed_in

      delete destroy_user_session_path

      post user_session_path, params: { user: { email: 'both@example.com', password: 'their-own-password' } }

      expect(response).to have_http_status(:redirect)
      expect_signed_in
    end

    # The callback's outbound token exchange with Google is made by OmniAuth's
    # own middleware, before any controller of ours runs, so the ceiling that
    # protects it sits in RegistrationGateMiddleware in front of the strategy.
    # One request reaches that exchange and so one request spends a count: a
    # callback carrying the state OmniAuth minted for this session. Someone
    # driving the whole flow in their own browser can repeat that as fast as
    # they like — and is refused once the hour's sixty are gone.
    it 'refuses the state-carrying callback past the per-network attempt ceiling, in front of Google' do
      mock_google(email: 'grace@example.com')

      Quotas::Limits::OAUTH_ATTEMPTS_PER_IP_PER_HOUR.times do
        get user_google_oauth2_omniauth_callback_path(state: start_google_flow!)

        expect(response).to have_http_status(:redirect)
      end

      get user_google_oauth2_omniauth_callback_path(state: start_google_flow!)

      expect(response).to have_http_status(:too_many_requests)
      expect(User.count).to eq(2)
    end

    # The ceiling must never become a weapon against our own users: a
    # malicious page can make an innocent visitor's browser issue requests
    # under the OmniAuth prefix cross-origin (plain <img> tags will do), and
    # it cannot read or set that browser's OmniAuth state. So everything that
    # could not reach Google's token endpoint passes through uncounted — a
    # path that routes nowhere, a callback with no state, a callback carrying
    # a state from somewhere else — and the visitor's hour is untouched.
    it 'spends no attempt on a stray path or a callback without this session\'s state' do
      mock_google(email: 'grace@example.com')

      (Quotas::Limits::OAUTH_ATTEMPTS_PER_IP_PER_HOUR + 1).times do
        expect { get '/auth/anything' }.to raise_error(ActionController::RoutingError)

        get user_google_oauth2_omniauth_callback_path
        expect(response).to have_http_status(:redirect)

        get user_google_oauth2_omniauth_callback_path(state: 'a-state-from-somewhere-else')
        expect(response).to have_http_status(:redirect)
      end

      # The honest visitor still gets in...
      sign_in_with_google!

      expect(response).to redirect_to(root_path)
      expect_signed_in

      # ...on an allowance not one of those 183 requests touched.
      expect { Quotas::Limits::OAUTH_ATTEMPTS_PER_IP_PER_HOUR.times { Registrations.assert_oauth_attempt_allowed!('127.0.0.1') } }
        .not_to raise_error
    end

    it 'signs an existing confirmed user in without touching their account' do
      user = create(:user, email: 'member@example.com')
      mock_google(email: 'Member@example.com')

      expect { sign_in_with_google! }.not_to change(User, :count)
      expect(response).to redirect_to(root_path)
      expect(user.reload.account.users.count).to eq(1)
      expect_signed_in
    end

    it 'refuses an unverified Google address, a disposable one and a failed exchange, creating nothing' do
      mock_google(email: 'unverified@example.com', verified: false)

      expect { sign_in_with_google! }.not_to change(User, :count)
      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('google_email_not_verified'))
      expect_signed_out

      mock_google(email: 'burner@mailinator.com')

      expect { sign_in_with_google! }.not_to change(User, :count)
      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('please_use_a_permanent_email_address'))
      expect_signed_out

      OmniAuth.config.mock_auth[:google_oauth2] = :invalid_credentials

      expect { sign_in_with_google! }.not_to change(User, :count)
      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('google_sign_in_failed'))
      expect_signed_out
      expect(Account.count).to eq(1)
    end

    it 'sends a two-factor user to the password form instead of bypassing their code' do
      user = create(:user, email: 'careful@example.com', otp_required_for_login: true,
                           otp_secret: User.generate_otp_secret)
      mock_google(email: 'careful@example.com')

      sign_in_with_google!

      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('google_sign_in_not_available_with_2fa'))
      expect(user.reload.sign_in_count).to eq(0)
      expect_signed_out
    end

    it 'applies the per-network limit to Google sign-ups too' do
      Quotas::Limits::SIGNUPS_PER_IP_PER_HOUR.times { Registrations.assert_ip_allowed!('127.0.0.1') }
      mock_google(email: 'late@example.com')

      expect { sign_in_with_google! }.not_to change(User, :count)
      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('too_many_sign_ups_from_this_network'))
      expect_signed_out
    end

    it 'answers 404 for the authorize and callback endpoints while the switch is off' do
      ENV.delete('REGISTRATION_ENABLED')
      mock_google(email: 'grace@example.com')

      post user_google_oauth2_omniauth_authorize_path
      expect(response).to have_http_status(:not_found)

      get user_google_oauth2_omniauth_callback_path
      expect(response).to have_http_status(:not_found)
      expect(User.count).to eq(1)
    end

    # Either credential missing is the same answer: no Google endpoints and no
    # button — both are required (with only the id the button would render and
    # the exchange would fail after the bounce to Google).
    [['GOOGLE_OAUTH_CLIENT_ID', 'the Google client id is unset, instead of bouncing to Google'],
     ['GOOGLE_OAUTH_CLIENT_SECRET', 'only the client secret is unset (both credentials are required)']]
      .each do |variable, description|
      it "answers 404 for the Google endpoints while #{description}" do
        ENV.delete(variable)
        mock_google(email: 'grace@example.com')

        post user_google_oauth2_omniauth_authorize_path
        expect(response).to have_http_status(:not_found)

        get user_google_oauth2_omniauth_callback_path
        expect(response).to have_http_status(:not_found)
        expect(User.count).to eq(1)

        get new_registration_path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(google_button)
      end
    end

    it 'refuses a locked user (too many wrong passwords) instead of signing them in through Google' do
      user = create(:user, email: 'locked@example.com')
      user.lock_access!(send_instructions: false)
      mock_google(email: 'locked@example.com')

      sign_in_with_google!

      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('devise.failure.locked'))
      expect(user.reload.sign_in_count).to eq(0)
      expect(user.access_locked?).to be(true)
      expect_signed_out
    end

    # A closed login is the one case where Google having proved the mailbox
    # must NOT open a door. The address still belongs to a row we archived —
    # a person removed from a team, or a whole account on its way out — so the
    # callback refuses it in plain words instead of adopting the row or, worse,
    # treating the address as a stranger's and minting a second account on it.
    # Both halves are checked: the person's own row archived, and the account
    # underneath an otherwise-live person archived.
    it 'refuses an archived user and an archived account, creating nothing and signing nobody in' do
      archived_user = create(:user, email: 'closed@example.com', archived_at: Time.current)
      mock_google(email: 'closed@example.com')

      expect { sign_in_with_google! }.not_to(change { [User.count, Account.count] })
      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('this_account_is_no_longer_active'))
      expect(archived_user.reload).to have_attributes(sign_in_count: 0, archived_at: be_present)
      expect_signed_out

      member = create(:user, email: 'ghost@example.com')
      member.account.update!(archived_at: Time.current)
      mock_google(email: 'ghost@example.com')

      expect { sign_in_with_google! }.not_to(change { [User.count, Account.count] })
      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('this_account_is_no_longer_active'))
      expect(member.reload.sign_in_count).to eq(0)
      expect_signed_out
    end

    it 'stamps a new account with the timezone the sign-in button carried' do
      mock_google(email: 'paris@example.com')

      expect { sign_in_with_google!(timezone: 'Europe/Paris') }.to change(Account, :count).by(1)
      expect(signed_up_user('paris@example.com').account.timezone).to eq('Paris')

      mock_google(email: 'nowhere@example.com')

      expect { sign_in_with_google!(timezone: 'Mars/Olympus') }.to change(Account, :count).by(1)
      expect(signed_up_user('nowhere@example.com').account.timezone).to eq('UTC')
    end

    it 'tells the loser of two simultaneous Google sign-ups for one address that it is taken, without a 500' do
      mock_google(email: 'race@example.com')
      allow(Registrations).to receive(:build_signup).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap do |user|
          allow(user).to receive(:save).and_raise(ActiveRecord::RecordNotUnique, 'duplicate key value')
        end
      end

      expect { sign_in_with_google! }.not_to change(Account, :count)
      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to include('already been taken')
      expect_signed_out
    end
  end

  describe 'routes' do
    it 'draws only new, create and the check-your-email page — never Devise registration editing' do
      route_names = Rails.application.routes.routes.filter_map(&:name).grep(/registration/)

      expect(route_names).to match_array(%w[new_registration registration confirm_registration])
      expect(Rails.application.routes.url_helpers).not_to respond_to(:edit_user_registration_path)
      expect(Rails.application.routes.url_helpers).not_to respond_to(:user_registration_path)
      expect(Rails.application.routes.url_helpers).not_to respond_to(:cancel_user_registration_path)

      enable_registration!

      expect { delete '/sign_up' }.to raise_error(ActionController::RoutingError)
      expect { put '/sign_up' }.to raise_error(ActionController::RoutingError)
      expect { get '/sign_up/edit' }.to raise_error(ActionController::RoutingError)
    end
  end

  describe 'paranoid mode' do
    it 'is on, and the confirmation and password forms answer alike for known and unknown addresses' do
      expect(Devise.paranoid).to be(true)

      get new_user_confirmation_path
      expect(response).to have_http_status(:not_found)

      enable_registration!
      unconfirmed = create(:user, email: 'known@example.com', confirmed_at: nil)

      get new_user_confirmation_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="user[email]"')

      expect do
        post user_confirmation_path, params: { user: { email: 'known@example.com' } }
      end.to change(ActionMailer::Base.deliveries, :count).by(1)
      known_location = response.location
      known_flash = flash[:notice]

      expect do
        post user_confirmation_path, params: { user: { email: 'nobody@example.com' } }
      end.not_to change(ActionMailer::Base.deliveries, :count)
      expect(response.location).to eq(known_location)
      expect(flash[:notice]).to eq(known_flash)
      expect(unconfirmed.reload.confirmation_sent_at).to be_present

      post user_password_path, params: { user: { email: 'known@example.com' } }
      known_location = response.location

      expect do
        post user_password_path, params: { user: { email: 'nobody@example.com' } }
      end.not_to change(ActionMailer::Base.deliveries, :count)
      expect(response.location).to eq(known_location)
    end
  end

  describe 'content security policy' do
    it 'allows the Turnstile host on the sign-up page only' do
      enable_registration!

      get new_registration_path
      policy = response.headers['Content-Security-Policy']
      expect(policy).to match(%r{script-src [^;]*https://challenges\.cloudflare\.com})
      expect(policy).to match(%r{frame-src [^;]*https://challenges\.cloudflare\.com})

      get new_user_session_path
      expect(response.headers['Content-Security-Policy']).not_to include('challenges.cloudflare.com')

      # The check-your-email page has no widget, so the exception does not
      # reach it: the policy stays as tight as every other page's.
      get confirm_registration_path
      expect(response.headers['Content-Security-Policy']).not_to include('challenges.cloudflare.com')
    end
  end

  describe Turnstile do
    it 'fails closed on a blank token, a missing secret and a malformed answer' do
      expect { described_class.verify!('', '127.0.0.1') }.to raise_error(Turnstile::VerificationFailed)
      expect(described_class.enabled?).to be(false)
      expect { described_class.verify!('token', '127.0.0.1') }.to raise_error(Turnstile::VerificationFailed)

      ENV['TURNSTILE_SECRET_KEY'] = 'turnstile-secret-key'
      stub_request(:post, Turnstile::VERIFY_URL).to_return(status: 200, body: 'not json')
      allow(ErrorReport).to receive(:warning)

      expect { described_class.verify!('token', '127.0.0.1') }.to raise_error(Turnstile::VerificationFailed)
      expect(ErrorReport).to have_received(:warning).with(kind_of(JSON::ParserError), remote_ip: '127.0.0.1')

      verification = stub_turnstile(success: true)

      expect(described_class.verify!('token', '10.0.0.7')).to be(true)
      expect(verification.with(body: hash_including('secret' => 'turnstile-secret-key', 'response' => 'token',
                                                    'remoteip' => '10.0.0.7'))).to have_been_requested
    end
  end

  describe RegistrationConfigGuard do
    def production!
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))
    end

    before do
      allow(ErrorReport).to receive(:warning)
      allow(Rails.logger).to receive(:warn)
    end

    it 'refuses to boot in production with registration on and no Turnstile keys' do
      ENV['REGISTRATION_ENABLED'] = 'true'
      production!

      expect { described_class.check! }.to raise_error(/TURNSTILE_SITE_KEY, TURNSTILE_SECRET_KEY/)

      ENV['TURNSTILE_SITE_KEY'] = 'site'
      expect { described_class.check! }.to raise_error(/TURNSTILE_SECRET_KEY/)
    end

    it 'only warns about missing Google credentials, and stays quiet with everything set' do
      enable_registration!
      production!

      expect { described_class.check! }.not_to raise_error
      expect(ErrorReport).to have_received(:warning).with(/GOOGLE_OAUTH_CLIENT_ID, GOOGLE_OAUTH_CLIENT_SECRET/)
      expect(Rails.logger).to have_received(:warn).with(/GOOGLE_OAUTH_CLIENT_ID, GOOGLE_OAUTH_CLIENT_SECRET/)

      enable_google!
      RSpec::Mocks.space.proxy_for(ErrorReport).reset
      allow(ErrorReport).to receive(:warning)

      expect { described_class.check! }.not_to raise_error
      expect(ErrorReport).not_to have_received(:warning)
    end

    it 'does nothing while registration is off or outside production' do
      production!
      expect { described_class.check! }.not_to raise_error

      ENV['REGISTRATION_ENABLED'] = 'true'
      allow(Rails).to receive(:env).and_call_original
      expect { described_class.check! }.not_to raise_error
      expect(ErrorReport).not_to have_received(:warning)
    end
  end
end
