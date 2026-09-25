# frozen_string_literal: true

RSpec.describe 'Personalization' do
  # Email templates are paid-only; the free-account CTA path is asserted in spec/golden/gating_ui_spec.rb.
  let!(:account) { create(:account, :paid) }
  let!(:user) { create(:user, account:) }

  before do
    sign_in(user)
    visit settings_personalization_path
  end

  it 'shows the personalization page' do
    expect(page).to have_content('Email Templates')
    expect(page).to have_content('Signature Request Email')
    expect(page).to have_content('Completed Notification Email')
    expect(page).to have_content('Documents Copy Email')
    expect(page).to have_content('Company Logo')
  end

  # A blank reply-to sends replies to whoever sent the document
  # (Submitters::ReplyTo), so the field shows the user's own address as that
  # default instead of saving it and pinning every teammate's replies to it.
  it 'shows the reply-to default as the signed-in user' do
    fields = all('input[type=email][name="account_config[value][reply_to]"]', visible: :all)

    expect(fields).not_to be_empty
    fields.each do |field|
      expect(field[:placeholder]).to eq(user.email)
      expect(field.value).to be_blank
    end
    expect(page).to have_css('p', text: 'If left blank, replies go to the person who sent the document.', visible: :all)
  end
end
