# frozen_string_literal: true

RSpec.describe 'PDF Signature Settings' do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account:) }

  # Session 4: certificates, the timestamp server and the PDF verification box
  # are platform-operator surfaces; the signing preferences on the same page
  # stay open to every account admin.
  it 'shows an account admin the preferences without the certificate or verification surfaces' do
    sign_in(user)
    visit settings_esign_path

    expect(page).to have_content('PDF Signature')
    expect(page).to have_content('Preferences')
    expect(page).to have_content('Remove PDF form fillable fields from the signed PDF (flatten form)')
    expect(page).to have_no_content('Upload signed PDF file to validate its signature')
    expect(page).to have_no_content('Verify Signed PDF')
    expect(page).to have_no_content('Signing Certificates')
    expect(page).to have_no_content('Timestamp Server')
  end

  it 'shows the platform operator the verification box, the certificates and the timestamp server' do
    operator = create(:user, :admin, account: create(:account, :operator), platform_operator: true)
    operator.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)

    sign_in(operator)
    visit settings_esign_path

    expect(page).to have_content('PDF Signature')
    expect(page).to have_content('Upload signed PDF file to validate its signature')
    expect(page).to have_content('Verify Signed PDF')
    expect(page).to have_content('Click to upload or drag and drop files')
    expect(page).to have_content('Signing Certificates')
    expect(page).to have_content('Timestamp Server')
    expect(page).to have_content('Preferences')
  end
end
