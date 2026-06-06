# frozen_string_literal: true

describe 'Personalization Logo' do
  let(:account) { create(:account) }
  let(:admin) { create(:user, :admin, account:) }
  let(:editor) { create(:user, :editor, account:) }
  let(:png) { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/sample-image.png'), 'image/png') }

  describe 'POST /settings/personalization_logo' do
    it 'lets an admin upload a company logo' do
      sign_in(admin)

      expect do
        post settings_personalization_logo_path, params: { logo: png }
      end.to change { account.reload.logo.attached? }.from(false).to(true)

      expect(response).to have_http_status(:redirect)
      expect(flash[:notice]).to be_present
    end

    it 'rejects a non-image file (content sniffed, not trusted)' do
      sign_in(admin)

      file = Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/sample-document.pdf'), 'image/png')

      post settings_personalization_logo_path, params: { logo: file }

      expect(account.reload.logo).not_to be_attached
      expect(flash[:alert]).to match(/PNG, JPG/)
    end

    it 'rejects an SVG upload (scriptable image type)' do
      sign_in(admin)

      svg = Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/sample-logo.svg'), 'image/png')

      post settings_personalization_logo_path, params: { logo: svg }

      expect(account.reload.logo).not_to be_attached
      expect(flash[:alert]).to match(/PNG, JPG/)
    end

    it 'forbids a non-admin (editor) from uploading a logo' do
      sign_in(editor)

      post settings_personalization_logo_path, params: { logo: png }

      expect(account.reload.logo).not_to be_attached
      expect(response).to redirect_to(root_path)
    end

    it 'forbids a non-admin (viewer) from uploading a logo' do
      sign_in(create(:user, :viewer, account:))

      post settings_personalization_logo_path, params: { logo: png }

      expect(account.reload.logo).not_to be_attached
      expect(response).to redirect_to(root_path)
    end

    it 'requires authentication' do
      admin # ensure an account/user exists so the first-run setup redirect does not trigger

      post settings_personalization_logo_path, params: { logo: png }

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'DELETE /settings/personalization_logo' do
    before do
      account.logo.attach(io: Rails.root.join('spec/fixtures/sample-image.png').open,
                          filename: 'logo.png', content_type: 'image/png')
    end

    it 'lets an admin remove the company logo' do
      sign_in(admin)

      delete settings_personalization_logo_path

      expect(response).to have_http_status(:redirect)
      expect(flash[:notice]).to be_present
    end

    it 'forbids a non-admin (editor) from removing the logo' do
      sign_in(editor)

      delete settings_personalization_logo_path

      expect(response).to redirect_to(root_path)
    end
  end
end
