# frozen_string_literal: true

# "What's your name?" (NamePromptsController). Sign-up names a new account
# after its owner's email address when no name came with it — an Apple sign-in
# where the person kept their name back — and that address is then the sender
# on every signer email. The dashboard asks the owner for a name once; saving
# it fixes both their own name and the account name, and the question never
# comes back.
RSpec.describe 'Name prompt', type: :request do
  let(:email) { 'x7k2q9@privaterelay.appleid.com' }
  let(:account) { create(:account, name: email) }
  let!(:user) { create(:user, account:, email:, first_name: nil, last_name: nil) }

  describe 'the dashboard' do
    it 'asks the owner of an account still named after their email address' do
      sign_in(user)

      get root_path

      expect(response).to redirect_to(name_prompt_path)
    end

    it 'asks however the address is capitalized' do
      account.update!(name: email.upcase)
      sign_in(user)

      get root_path

      expect(response).to redirect_to(name_prompt_path)
    end

    it 'leaves an account that has a name alone' do
      account.update!(name: 'Jane Smith')
      sign_in(user)

      get root_path

      expect(response).to have_http_status(:ok)
    end

    it 'leaves a teammate alone: the account name is not theirs to give' do
      teammate = create(:user, account:, role: User::EDITOR_ROLE, email: 'pat@example.com')
      account.update!(name: teammate.email)
      sign_in(teammate)

      get root_path

      expect(response).to have_http_status(:ok)
    end

    it 'leaves an operator account alone' do
      operator_account = create(:account, :operator, name: 'ops@example.com')
      operator = create(:user, account: operator_account, email: 'ops@example.com', platform_operator: true)
      sign_in(operator)

      get root_path

      expect(response).not_to redirect_to(name_prompt_path)
    end
  end

  describe 'the page' do
    before { sign_in(user) }

    it 'shows what a signer reads, and the one field' do
      get name_prompt_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML("What's your name?"), 'sent you')
      expect(response.body).to include('name="name"')
    end

    it 'saves the name on the person and the account, then never asks again' do
      post name_prompt_path, params: { name: '  Jane   Smith  ' }

      expect(response).to redirect_to(root_path)
      expect(user.reload).to have_attributes(first_name: 'Jane', last_name: 'Smith')
      expect(account.reload.name).to eq('Jane Smith')

      get root_path

      expect(response).to have_http_status(:ok)

      get name_prompt_path

      expect(response).to redirect_to(root_path)
    end

    it 'takes a single name' do
      post name_prompt_path, params: { name: 'Cher' }

      expect(user.reload).to have_attributes(first_name: 'Cher', last_name: nil)
      expect(account.reload.name).to eq('Cher')
    end

    it 'refuses a blank name and changes nothing' do
      post name_prompt_path, params: { name: '   ' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('Enter your name, not an email address.')
      expect(account.reload.name).to eq(email)
    end

    it 'refuses another email address, which would only ask again' do
      post name_prompt_path, params: { name: 'jane@example.com' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(account.reload.name).to eq(email)
      expect(user.reload.first_name).to be_nil
    end

    it 'sends anybody who has a name straight on' do
      account.update!(name: 'Jane Smith')

      get name_prompt_path
      expect(response).to redirect_to(root_path)

      post name_prompt_path, params: { name: 'Someone Else' }
      expect(response).to redirect_to(root_path)
      expect(account.reload.name).to eq('Jane Smith')
    end
  end

  describe 'a support session' do
    let(:operator_account) { create(:account, :operator) }
    let(:operator) do
      create(:user, :admin, account: operator_account, platform_operator: true,
                            otp_secret: User.generate_otp_secret, otp_required_for_login: true)
    end

    before do
      sign_in(operator)
      post operator_impersonations_path,
           params: { account_id: account.id, user_id: user.id, mode: SupportImpersonation::EDIT_MODE,
                     reason: 'Ticket 4182 — the customer cannot find their templates',
                     otp_attempt: operator.reload.current_otp }
    end

    it 'is not asked, and cannot give the customer a name' do
      get root_path

      expect(response).not_to redirect_to(name_prompt_path)

      post name_prompt_path, params: { name: 'Operator Guess' }

      expect(account.reload.name).to eq(email)
    end
  end
end
