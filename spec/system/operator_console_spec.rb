# frozen_string_literal: true

# The console in a real browser: the list, one account's page, and one action
# driven all the way through its confirmation dialog. The request specs prove
# what the doors do; this proves an operator can actually reach them — the
# dialog opens, the reason is typed into it, and the account moves.
RSpec.describe 'Operator console' do
  let!(:operator_account) { create(:account, :operator) }
  let!(:operator) do
    create(:user, :admin, account: operator_account, platform_operator: true).tap do |user|
      user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)
    end
  end
  let!(:account) { create(:account, name: 'Northfield Legal') }
  let!(:account_admin) { create(:user, :admin, account:) }

  before { sign_in(operator) }

  it 'lists every account and links into one' do
    visit operator_accounts_path

    expect(page).to have_content('Accounts')
    expect(page).to have_link('Northfield Legal')
    expect(page).to have_content('Free')
    expect(page).to have_no_content('translation missing')

    click_link 'Northfield Legal'

    expect(page).to have_content('Usage & limits')
    expect(page).to have_content('Plan & billing')
    expect(page).to have_content(account_admin.email)
    expect(page).to have_content('Deletion & retention')
    expect(page).to have_no_content('translation missing')
  end

  it 'suspends an account through the confirmation dialog and writes the audit row' do
    visit operator_account_path(account)

    click_button 'Suspend'

    within('#operator_action_suspend') do
      fill_in 'reason', with: 'Ticket 4182 — repeated complaints'
      click_button 'Suspend'
    end

    expect(page).to have_content('Account suspended.')
    expect(account.reload.suspended_at).to be_present
    expect(account.suspension_reason).to eq('operator')

    event = OperatorEvent.newest_first.first

    expect(event.action).to eq('account.suspend')
    expect(event.reason).to eq('Ticket 4182 — repeated complaints')
    expect(page).to have_content('Lift suspension')
  end

  it 'saves a limit override from the form and Quotas reads it back' do
    visit operator_account_path(account)

    fill_in 'limits[completions_per_month]', with: '42'
    fill_in 'limits[storage_gb]', with: '25'
    all('textarea[name="reason"]').first.set('Pilot customer, agreed in writing')

    within(format('form[action="%s"]', limits_operator_account_path(account))) do
      click_button 'Save limits'
    end

    expect(page).to have_content('Limits saved.')
    expect(Quotas.limits_for(account.reload).completions_per_month).to eq(42)
    expect(Quotas.limits_for(account).storage_bytes).to eq(25 * 1.gigabyte)
  end

  it 'hides the console from a customer administrator entirely' do
    sign_in(account_admin)

    visit settings_profile_index_path

    expect(page).to have_no_link(href: operator_accounts_path)
    expect(page).to have_no_content('Operator')
  end
end
