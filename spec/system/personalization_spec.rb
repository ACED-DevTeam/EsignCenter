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
end
