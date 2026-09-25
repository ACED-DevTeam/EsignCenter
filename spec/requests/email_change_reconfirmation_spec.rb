# frozen_string_literal: true

# A changed sign-in address only takes effect once somebody opens the link
# mailed TO the new address (launch security review, finding 1). Before this,
# anybody could rename their own login to an address they did not own and
# then collect that address's "Continue with Google" sign-ins and password
# resets. Nothing here ever matches a pending (`unconfirmed_email`) address.
RSpec.describe 'Email change reconfirmation', type: :request do
  stash_env 'REGISTRATION_ENABLED', 'TURNSTILE_SITE_KEY', 'TURNSTILE_SECRET_KEY',
            'GOOGLE_OAUTH_CLIENT_ID', 'GOOGLE_OAUTH_CLIENT_SECRET', clear: true

  let(:account) { create(:account) }
  let(:user) { create(:user, account:, email: 'owner@example.com', password: 'correct-password') }
  let(:victim_address) { 'ceo@victim.example' }
  let(:deliveries) { ActionMailer::Base.deliveries }

  before do
    # The instance is set up: sign-up pages are not the first-run redirect.
    create(:user, account: create(:account, :operator))
    RateLimit.store.clear
    deliveries.clear
    Sidekiq::Worker.clear_all
  end

  after do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end

  def confirmation_jobs
    SendConfirmationInstructionsJob.jobs
  end

  def deliver_confirmation!
    confirmation_jobs.each { |job| SendConfirmationInstructionsJob.new.perform(*job['args']) }
    confirmation_jobs.clear
  end

  def confirmation_token_from(mail)
    mail.body.encoded[/confirmation_token=([^"&\s]+)/, 1]
  end

  def change_own_email(email, current_password: nil)
    patch update_contact_settings_profile_index_path,
          params: { user: { first_name: user.first_name, last_name: user.last_name, email: },
                    current_password: }.compact
  end

  describe 'changing your own address from Profile' do
    before { sign_in(user) }

    it 'refuses without the current password, and changes nothing' do
      change_own_email(victim_address)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('wrong_password'))
      expect(user.reload.email).to eq('owner@example.com')
      expect(user.unconfirmed_email).to be_nil
      expect(confirmation_jobs).to be_empty
    end

    it 'refuses with a wrong current password' do
      change_own_email(victim_address, current_password: 'not-it')

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.email).to eq('owner@example.com')
      expect(user.unconfirmed_email).to be_nil
    end

    it 'holds the new address until the link mailed to it is opened, then switches' do
      change_own_email('new-owner@example.com', current_password: 'correct-password')

      expect(response).to redirect_to(settings_profile_index_path)
      expect(flash[:notice]).to eq(I18n.t('a_confirmation_email_has_been_sent_to_the_new_email_address'))
      expect(user.reload.email).to eq('owner@example.com')
      expect(user.unconfirmed_email).to eq('new-owner@example.com')
      expect(confirmation_jobs.size).to eq(1)
      # Devise's own after-commit mail is suppressed: one link, not two.
      expect(deliveries).to be_empty

      deliver_confirmation!

      mail = deliveries.sole
      expect(mail.to).to eq(['new-owner@example.com'])
      expect(mail.body.encoded).to include(
        I18n.t('confirm_this_address_to_finish_changing_your_product_email', product: Docuseal.product_name)
      )

      # Registration is OFF in this example: the link still works.
      get user_confirmation_path(confirmation_token: confirmation_token_from(mail))

      expect(response).to have_http_status(:redirect)
      expect(user.reload.email).to eq('new-owner@example.com')
      expect(user.unconfirmed_email).to be_nil
    end

    it 'changes the name alone without asking for a password' do
      patch update_contact_settings_profile_index_path,
            params: { user: { first_name: 'Renamed', last_name: user.last_name, email: 'OWNER@example.com' } }

      expect(response).to redirect_to(settings_profile_index_path)
      expect(user.reload.first_name).to eq('Renamed')
      expect(user.email).to eq('owner@example.com')
    end
  end

  describe 'an administrator changing a member address' do
    let(:member) { create(:user, account:, email: 'member@example.com', role: User::EDITOR_ROLE) }

    before { sign_in(user) }

    it 'only requests the change: the member address moves once the member confirms it' do
      patch user_path(member), params: { user: { email: 'member-new@example.com' } }

      expect(flash[:notice]).to eq(I18n.t('a_confirmation_email_has_been_sent_to_the_new_email_address'))
      expect(member.reload.email).to eq('member@example.com')
      expect(member.unconfirmed_email).to eq('member-new@example.com')

      deliver_confirmation!

      expect(deliveries.sole.to).to eq(['member-new@example.com'])

      get user_confirmation_path(confirmation_token: confirmation_token_from(deliveries.sole))

      expect(member.reload.email).to eq('member-new@example.com')
    end

    it 'never changes the administrator\'s own address from the team page' do
      patch user_path(user), params: { user: { email: victim_address, first_name: 'Still' } }

      expect(user.reload.first_name).to eq('Still')
      expect(user.email).to eq('owner@example.com')
      expect(user.unconfirmed_email).to be_nil
      expect(confirmation_jobs).to be_empty
    end
  end

  describe 'a pending address is nobody\'s sign-in' do
    before do
      sign_in(user)
      change_own_email(victim_address, current_password: 'correct-password')
      sign_out(:user)
      reset!
      deliveries.clear
    end

    it 'never signs "Continue with Google" for that address into the account that asked for it' do
      expect(user.reload.unconfirmed_email).to eq(victim_address)
      ENV['REGISTRATION_ENABLED'] = 'true'
      ENV['GOOGLE_OAUTH_CLIENT_ID'] = 'google-client-id'
      ENV['GOOGLE_OAUTH_CLIENT_SECRET'] = 'google-client-secret'
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:google_oauth2] =
        OmniAuth::AuthHash.new(provider: 'google_oauth2', uid: '1', info: { email: victim_address, name: 'CEO' },
                               extra: { raw_info: { email_verified: true } })

      post user_google_oauth2_omniauth_authorize_path(LegalDocuments.version_fields)
      follow_redirect!

      signed_in = User.find_by(email: victim_address)

      expect(signed_in).to be_present
      expect(signed_in.id).not_to eq(user.id)
      expect(signed_in.account_id).not_to eq(account.id)
      expect(user.reload.email).to eq('owner@example.com')
    end

    it 'never mails a password reset for that address to anybody' do
      post user_password_path, params: { user: { email: victim_address } }

      expect(deliveries).to be_empty
      expect(user.reload.reset_password_token).to be_nil
    end

    it 'cannot sign in with a password under that address' do
      post user_session_path, params: { user: { email: victim_address, password: 'correct-password' } }

      get settings_profile_index_path

      expect(response).not_to have_http_status(:ok)
    end
  end

  it 'answers a dead confirmation link with a plain 404 while registration is off' do
    get user_confirmation_path(confirmation_token: 'not-a-token')

    expect(response).to have_http_status(:not_found)
  end
end
