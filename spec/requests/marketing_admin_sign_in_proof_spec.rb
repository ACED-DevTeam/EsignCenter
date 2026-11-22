# frozen_string_literal: true

# The private marketing page asks more of a session than being signed in as a
# listed user (MarketingAdmin::MailboxProof). The app signs somebody in to an
# existing login whenever Google or Apple vouches for its address, and for an
# address they do not host themselves that mark can outlive the person's hold
# on the mailbox — a former holder who kept their old Google account would be
# signed in as the listed user. So the page opens only for a session that was
# opened in a way that proves who is using it, and is a 404 for every other.
#
# Nothing here may change ordinary sign-in: whoever is refused the page is
# still signed in exactly as before.
RSpec.describe 'Marketing admin page: how the session was opened', type: :request do
  stash_env 'MARKETING_ADMIN_EMAILS', 'REGISTRATION_ENABLED', 'TURNSTILE_SITE_KEY', 'TURNSTILE_SECRET_KEY',
            'GOOGLE_OAUTH_CLIENT_ID', 'GOOGLE_OAUTH_CLIENT_SECRET', 'APPLE_OAUTH_CLIENT_ID', 'APPLE_OAUTH_TEAM_ID',
            'APPLE_OAUTH_KEY_ID', 'APPLE_OAUTH_PRIVATE_KEY', clear: true

  let(:proof) { MarketingAdmin::MailboxProof }

  before do
    ENV['REGISTRATION_ENABLED'] = 'true'
    ENV['TURNSTILE_SITE_KEY'] = 'turnstile-site-key'
    ENV['TURNSTILE_SECRET_KEY'] = 'turnstile-secret-key'
    ENV['GOOGLE_OAUTH_CLIENT_ID'] = 'google-client-id'
    ENV['GOOGLE_OAUTH_CLIENT_SECRET'] = 'google-client-secret'
    ENV['APPLE_OAUTH_CLIENT_ID'] = 'com.esigncenter.web'
    ENV['APPLE_OAUTH_TEAM_ID'] = 'AB1234CD56'
    ENV['APPLE_OAUTH_KEY_ID'] = 'EF7890GH12'
    ENV['APPLE_OAUTH_PRIVATE_KEY'] = OpenSSL::PKey::EC.generate('prime256v1').to_pem
    RateLimit.store.clear
    # The instance is set up, so a sign-up is never the first-run redirect.
    create(:user, account: create(:account, :operator))
  end

  after do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.mock_auth[:apple] = nil
  end

  # Somebody who made their own login for a listed address, with a password.
  def listed_user(email)
    ENV['MARKETING_ADMIN_EMAILS'] = email

    signed_up_themselves(create(:user, email:))
  end

  # What Google hands back. `hd` is the Workspace domain claim: in the ID
  # token (`id_info`) and in the profile (`raw_info`); an ordinary Google
  # account has neither, whatever address it was made with.
  def sign_in_with_google(email, id_token_hd: nil, profile_hd: nil)
    extra = { raw_info: { email_verified: true, hd: profile_hd }.compact }
    extra[:id_info] = { 'email' => email, 'email_verified' => true, 'hd' => id_token_hd }.compact if id_token_hd

    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] =
      OmniAuth::AuthHash.new(provider: 'google_oauth2', uid: '1076915035', info: { email:, name: 'Grace Hopper' },
                             extra:)

    post user_google_oauth2_omniauth_authorize_path(LegalDocuments.version_fields)
    follow_redirect!
  end

  def sign_in_with_apple(email)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:apple] =
      OmniAuth::AuthHash.new(provider: 'apple', uid: '001234.fedcba',
                             info: { email:, name: 'Grace Hopper', email_verified: true })

    post user_apple_omniauth_authorize_path(LegalDocuments.version_fields)
    post user_apple_omniauth_callback_path
  end

  def expect_signed_in_as(user)
    get settings_profile_index_path

    expect(response).to have_http_status(:ok)
    expect(controller.current_user).to eq(user)
  end

  def expect_page_open
    get '/admin'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-marketing-admin')
  end

  # Signed in, and the page does not exist: no link, a 404, and the buttons too.
  def expect_page_hidden_from(user)
    expect_signed_in_as(user)
    expect(response.body).not_to include('marketing_admin_button')
    expect { get '/admin' }.to raise_error(ActionController::RoutingError)
    expect { post '/admin/tiktok', params: { followers: '5' } }.to raise_error(ActionController::RoutingError)
    expect { post '/admin/refresh' }.to raise_error(ActionController::RoutingError)
  end

  describe 'Google' do
    # The case the review found. A custom-domain address that is not a Google
    # Workspace one: Google says "verified" for whoever made a Google account
    # with it, however long ago.
    it 'signs a listed user in as always, but does not open the page, when Google is not the authority' do
      user = listed_user('marketer@smallfirm.example')

      sign_in_with_google('marketer@smallfirm.example')

      expect(response).to redirect_to(root_path)
      expect_page_hidden_from(user)
    end

    it 'opens the page for a Google Workspace sign-in whose domain is the address’s own' do
      user = listed_user('marketer@smallfirm.example')

      sign_in_with_google('marketer@smallfirm.example', id_token_hd: 'smallfirm.example')

      expect_signed_in_as(user)
      expect_page_open
    end

    it 'reads the Workspace domain from the profile when the ID token was not kept' do
      listed_user('marketer@smallfirm.example')

      sign_in_with_google('marketer@smallfirm.example', profile_hd: 'SmallFirm.Example')

      expect_page_open
    end

    it 'does not open the page when the Workspace domain is somebody else’s' do
      user = listed_user('marketer@smallfirm.example')

      sign_in_with_google('marketer@smallfirm.example', id_token_hd: 'another-company.example')

      expect_page_hidden_from(user)
    end

    it 'opens the page for a gmail.com address, which Google hosts' do
      listed_user('marketer.person@gmail.com')

      sign_in_with_google('marketer.person@gmail.com')

      expect_page_open
    end

    it 'does not treat a look-alike of gmail.com as Google’s' do
      user = listed_user('marketer@gmail.com.evil.example')

      sign_in_with_google('marketer@gmail.com.evil.example')

      expect_page_hidden_from(user)
    end

    # The same weakness on the way in: a stranger who creates the login with
    # a non-authoritative Google sign-in owns nothing the page accepts.
    it 'does not open the page for a login just created by a non-authoritative Google sign-in' do
      ENV['MARKETING_ADMIN_EMAILS'] = 'marketer@smallfirm.example'

      sign_in_with_google('marketer@smallfirm.example')

      expect_page_hidden_from(User.find_by!(email: 'marketer@smallfirm.example'))
    end

    it 'changes nothing for somebody who is not on the list, and writes nothing into their session' do
      ENV['MARKETING_ADMIN_EMAILS'] = 'marketer@smallfirm.example'
      customer = create(:user, email: 'customer@gmail.com')

      sign_in_with_google('customer@gmail.com')

      expect(response).to redirect_to(root_path)
      expect_signed_in_as(customer)
      expect(request.env['warden'].session(:user)).not_to have_key(proof::KEY)
    end
  end

  describe 'Apple' do
    it 'does not open the page for an address Apple merely once verified' do
      user = listed_user('marketer@smallfirm.example')

      sign_in_with_apple('marketer@smallfirm.example')

      expect_page_hidden_from(user)
    end

    it 'opens the page for an address Apple hosts' do
      listed_user('marketer@icloud.com')

      sign_in_with_apple('marketer@icloud.com')

      expect_page_open
    end
  end

  describe 'a password' do
    it 'opens the page for the login’s own password' do
      user = listed_user('marketer@smallfirm.example')

      sign_in_with_password(user)

      expect_page_open
      expect(request.env['warden'].session(:user)[proof::KEY]).to include('how' => 'password', 'user_id' => user.id)
    end

    it 'opens the page for a password with its two-factor code' do
      user = listed_user('marketer@smallfirm.example')
      user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)

      post user_session_path, params: { user: { email: user.email, password: 'password',
                                                otp_attempt: user.current_otp } }

      expect_page_open
    end

    it 'does not open it for a wrong password, or for nobody' do
      user = listed_user('marketer@smallfirm.example')

      post user_session_path, params: { user: { email: user.email, password: 'not-the-password' } }

      expect { get '/admin' }.to raise_error(ActionController::RoutingError)
    end

    # Finishing a reset is done from a link mailed to the address minutes ago.
    it 'opens the page after a password reset finished from the mailed link' do
      user = listed_user('marketer@smallfirm.example')
      token = user.send(:set_reset_password_token)

      put user_password_path, params: { user: { reset_password_token: token, password: 'a-brand-new-password',
                                                password_confirmation: 'a-brand-new-password' } }

      expect_signed_in_as(user)
      expect(request.env['warden'].session(:user)[proof::KEY]).to include('how' => 'password_reset')
      expect_page_open
    end

    it 'writes nothing into the session of somebody who is not on the list' do
      ENV['MARKETING_ADMIN_EMAILS'] = 'marketer@smallfirm.example'
      customer = create(:user)

      sign_in_with_password(customer)

      expect_signed_in_as(customer)
      expect(request.env['warden'].session(:user)).not_to have_key(proof::KEY)
    end
  end

  describe 'a session with no proof in it' do
    # Every session that was already open when this shipped, and anything
    # else that puts a user in the session without them proving anything.
    it 'does not open the page for a session that carries no proof at all' do
      user = listed_user('marketer@smallfirm.example')

      sign_in(user)

      expect_page_hidden_from(user)
    end

    # The remember-me cookie signs somebody back in after the browser was
    # closed. It was minted by SOME earlier sign-in — possibly the weak kind.
    it 'does not open the page for a session restored from the remember-me cookie, until they sign in again' do
      user = listed_user('marketer@smallfirm.example')

      sign_in_with_password(user)
      expect_page_open

      session_cookie = Rails.application.config.session_options[:key]
      cookies.delete(session_cookie)

      expect_page_hidden_from(user)

      sign_out_for_real
      sign_in_with_password(user)

      expect_page_open
    end

    it 'does not keep a proof for ever' do
      user = listed_user('marketer@smallfirm.example')

      sign_in_with_password(user)
      expect_page_open

      travel_to(29.days.from_now) { expect_page_open }
      travel_to(31.days.from_now) { expect_page_hidden_from(user) }
    end

    it 'does not carry a proof over to the next person to sign in on the same browser' do
      first = listed_user('marketer@smallfirm.example')
      sign_in_with_password(first)
      expect_page_open

      ENV['MARKETING_ADMIN_EMAILS'] = 'marketer@smallfirm.example, second@smallfirm.example'
      second = signed_up_themselves(create(:user, email: 'second@smallfirm.example'))

      # Not signed out in between: Google signs the second person in over the first.
      sign_in_with_google('second@smallfirm.example')

      expect_page_hidden_from(second)
    end

    it 'does not bring an old proof back when the first person signs in again in a weaker way' do
      ENV['MARKETING_ADMIN_EMAILS'] = 'marketer@smallfirm.example, second@smallfirm.example'
      first = listed_user('marketer@smallfirm.example')
      second = signed_up_themselves(create(:user, email: 'second@smallfirm.example'))

      sign_in_with_password(first)
      expect_page_open

      # Somebody else signs in over them, then the first login comes back
      # through Google, which is not the authority for this address.
      sign_in_with_google('second@smallfirm.example')
      expect_page_hidden_from(second)

      sign_in_with_google('marketer@smallfirm.example')
      expect_signed_in_as(first)
      expect_page_hidden_from(first)
    end

    it 'drops the proof when the same login signs in again in a weaker way' do
      user = listed_user('marketer@smallfirm.example')

      sign_in_with_password(user)
      expect_page_open

      sign_in_with_google('marketer@smallfirm.example')
      expect_signed_in_as(user)
      expect_page_hidden_from(user)
    end

    it 'does not honour a proof given for an address the login has since left' do
      user = listed_user('marketer@smallfirm.example')
      ENV['MARKETING_ADMIN_EMAILS'] = 'marketer@smallfirm.example, new.address@smallfirm.example'

      sign_in_with_password(user)
      expect_page_open

      user.update_columns(email: 'new.address@smallfirm.example')

      expect { get '/admin' }.to raise_error(ActionController::RoutingError)
    end
  end

  describe MarketingAdmin::MailboxProof do
    it 'takes Google as the authority for gmail.com and for a Workspace domain that matches the address' do
      expect(described_class.google_authoritative?('a@gmail.com', nil)).to be(true)
      expect(described_class.google_authoritative?('A@GMAIL.COM', nil)).to be(true)
      expect(described_class.google_authoritative?('a@firm.example', 'firm.example')).to be(true)
      expect(described_class.google_authoritative?('a@firm.example', ' Firm.Example ')).to be(true)

      [['a@firm.example', nil], ['a@firm.example', ''], ['a@firm.example', 'other.example'],
       ['a@firm.example', 'gmail.com'], ['a@sub.firm.example', 'firm.example'], ['a@googlemail.com', nil],
       ['a@notgmail.com', nil], ['a@gmail.com.evil.example', nil], ['gmail.com', nil], ['a@b@gmail.com', nil],
       ['', 'firm.example'], [nil, nil], ['a@firm.example', ['firm.example']]].each do |email, hosted_domain|
        expect(described_class.google_authoritative?(email, hosted_domain)).to be(false), [email, hosted_domain].inspect
      end
    end

    it 'takes Apple as the authority only for the mailboxes Apple hosts' do
      %w[a@icloud.com a@me.com a@mac.com abc123@privaterelay.appleid.com A@ICLOUD.COM].each do |email|
        expect(described_class.apple_authoritative?(email)).to be(true), email
      end

      ['a@firm.example', 'a@gmail.com', 'a@icloud.com.evil.example', 'icloud.com', nil].each do |email|
        expect(described_class.apple_authoritative?(email)).to be(false), email.inspect
      end
    end

    it 'accepts only a proof for this user, at this address, of a known kind, that is still fresh' do
      user = create(:user, email: 'marketer@smallfirm.example')
      good = { 'user_id' => user.id, 'email' => user.email, 'how' => 'password', 'at' => Time.current.to_i }
      session = ->(value) { instance_double(Warden::Proxy, session: { described_class::KEY => value }) }

      expect(described_class.present?(session.call(good), user)).to be(true)

      [nil, 'yes', [], {}, good.merge('user_id' => user.id + 1), good.merge('email' => 'other@smallfirm.example'),
       good.merge('how' => 'remember_me'), good.merge('how' => nil), good.merge('at' => nil),
       good.merge('at' => 31.days.ago.to_i), good.merge('at' => 1.hour.from_now.to_i),
       good.merge('at' => Time.current.to_s)].each do |value|
        expect(described_class.present?(session.call(value), user)).to be(false), value.inspect
      end

      expect(described_class.present?(nil, user)).to be(false)

      signed_out = instance_double(Warden::Proxy)
      allow(signed_out).to receive(:session).and_raise(Warden::NotAuthenticated)

      expect(described_class.present?(signed_out, user)).to be(false)
    end

    it 'never fails a sign-in because the proof could not be written' do
      ENV['MARKETING_ADMIN_EMAILS'] = 'marketer@smallfirm.example'
      user = create(:user, email: 'marketer@smallfirm.example')
      broken = instance_double(Warden::Proxy)
      allow(broken).to receive(:session).and_raise(Warden::NotAuthenticated)
      allow(ErrorReport).to receive(:error)

      expect(described_class.record!(broken, user, 'password')).to be_nil
      expect(ErrorReport).to have_received(:error)
    end
  end
end
