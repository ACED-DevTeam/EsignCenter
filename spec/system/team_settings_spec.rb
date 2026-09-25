# frozen_string_literal: true

RSpec.describe 'Team Settings' do
  # Seats to invite into: free accounts have one (spec/golden/quota_spec.rb
  # proves the refusal); these examples are about the invitation UI itself.
  let(:account) { create(:account, :paid, seats: 5) }
  let(:second_account) { create(:account) }
  let(:current_user) { create(:user, account:) }

  before do
    sign_in(current_user)
  end

  context 'when multiple users' do
    let!(:users) { create_list(:user, 2, account:) }
    let!(:other_user) { create(:user) }

    before do
      visit settings_users_path
    end

    it 'shows only active users' do
      within '.table' do
        users.each do |user|
          expect(page).to have_content(user.full_name)
          expect(page).to have_content(user.email)
          expect(page).to have_link('Edit', href: edit_user_path(user))
        end

        expect(page).to have_button('Remove')
        expect(page).to have_no_button('Unarchive')

        expect(page).to have_no_content(other_user.full_name)
        expect(page).to have_no_content(other_user.email)
      end
    end

    # Session 7 Phase B: on a customer account the modal writes an INVITATION
    # that holds the seat, and the person chooses their own name and password
    # when they accept it (docs/billing.md §11). Internal and operator
    # accounts still create the user outright.
    it 'invites a new person and holds a seat for them' do
      click_link 'New User'

      within '#modal' do
        fill_in 'Email', with: 'joseph.smith@example.com'

        click_button 'Send invitation'
      end

      expect(page).to have_content('User has been invited')

      invite = AccountInvite.last

      expect(invite.email).to eq('joseph.smith@example.com')
      expect(invite.account).to eq(account)
      expect(invite).to be_pending
      expect(User.find_by(email: 'joseph.smith@example.com')).to be_nil
    end

    it "doesn't invite somebody who is already in the account" do
      click_link 'New User'

      within '#modal' do
        fill_in 'Email', with: users.first.email

        expect do
          click_button 'Send invitation'
        end.not_to change(AccountInvite, :count)
      end

      expect(page).to have_content('Email already exists')
    end

    # D50: this used to be "Email has already been taken", which left the
    # invitee with nothing to click. It is now an invitation that offers to
    # move them and their documents into this team
    # (spec/golden/seats_spec.rb).
    it 'offers to move somebody who already has an account of their own' do
      user = create(:user, account: second_account)
      visit settings_users_path

      click_link 'New User'

      within '#modal' do
        fill_in 'Email', with: user.email

        click_button 'Send invitation'
      end

      expect(page).to have_content('User has been invited')
      expect(page).to have_no_content('already been taken')

      invite = AccountInvite.find_by!(email: user.email)

      expect(invite.collision_user).to eq(user)
      expect(user.reload.account).to eq(second_account)
    end

    it 'does not allow an invitation to an invalid email' do
      click_link 'New User'

      within '#modal' do
        fill_in 'Email', with: 'joseph.smith@gmail'

        expect do
          click_button 'Send invitation'
        end.not_to change(AccountInvite, :count)

        expect(page).to have_content('Email is invalid')
      end
    end

    # An administrator can REQUEST a member's new address, never complete
    # it: it takes effect once the member opens the link mailed to it (launch
    # security review; spec/requests/email_change_reconfirmation_spec.rb).
    it 'updates a user, holding the new email until the member confirms it' do
      edited = users.last
      original_email = edited.email

      first(:link, 'Edit', href: edit_user_path(edited)).click

      fill_in 'First name', with: 'Adam'
      fill_in 'Last name', with: 'Meier'
      fill_in 'Email', with: 'adam.meier@example.com'

      expect do
        click_button 'Submit'
      end.not_to change(User, :count)

      expect(page).to have_content(I18n.t('a_confirmation_email_has_been_sent_to_the_new_email_address'))

      edited.reload

      expect(edited.first_name).to eq('Adam')
      expect(edited.last_name).to eq('Meier')
      expect(edited.email).to eq(original_email)
      expect(edited.unconfirmed_email).to eq('adam.meier@example.com')
    end

    it 'removes a user' do
      expect do
        accept_confirm('Are you sure?') do
          first(:button, 'Remove').click
        end
      end.to change { User.active.count }.by(-1)

      expect(page).to have_content('User has been removed')
    end
  end

  context 'when single user' do
    before do
      visit settings_users_path
    end

    it 'does not allow to remove the current user' do
      expect(page).to have_no_content('User has been removed')
    end
  end

  context 'when some users are archived' do
    let!(:users) { create_list(:user, 2, account:) }
    let!(:archived_users) { create_list(:user, 2, account:, archived_at: Time.current) }
    let!(:other_user) { create(:user) }

    it 'shows only active users' do
      visit settings_users_path

      within '.table' do
        users.each do |user|
          expect(page).to have_content(user.full_name)
          expect(page).to have_content(user.email)
        end

        archived_users.each do |user|
          expect(page).to have_no_content(user.full_name)
          expect(page).to have_no_content(user.email)
        end

        expect(page).to have_no_content(other_user.full_name)
        expect(page).to have_no_content(other_user.email)
      end

      expect(page).to have_link('View Archived', href: settings_archived_users_path)
    end

    it 'shows only archived users' do
      visit settings_archived_users_path

      within '.table' do
        archived_users.each do |user|
          expect(page).to have_content(user.full_name)
          expect(page).to have_content(user.email)
          expect(page).to have_no_link('Edit', href: edit_user_path(user))
        end

        users.each do |user|
          expect(page).to have_no_content(user.full_name)
          expect(page).to have_no_content(user.email)
          expect(page).to have_no_link('Edit', href: edit_user_path(user))
        end

        expect(page).to have_button('Unarchive')
        expect(page).to have_no_button('Remove')

        expect(page).to have_no_content(other_user.full_name)
        expect(page).to have_no_content(other_user.email)
      end

      expect(page).to have_content('Archived Users')
      expect(page).to have_link('View Active', href: settings_users_path)
    end
  end
end
