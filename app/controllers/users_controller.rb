# frozen_string_literal: true

class UsersController < ApplicationController
  before_action :authorize_account_management!

  load_and_authorize_resource :user, only: %i[index edit update destroy]

  before_action :build_user, only: %i[new create]
  authorize_resource :user, only: %i[new create]

  def index
    @users =
      if params[:status] == 'archived'
        @users.archived.where.not(role: 'integration')
      elsif params[:status] == 'integration'
        @users.active.where(role: 'integration')
      else
        @users.active.where.not(role: 'integration')
      end

    @users = @users.preload(account: :account_accesses).where(account: current_account).order(id: :desc)

    respond_to do |format|
      format.html do
        @pagy, @users = pagy(@users)
      end

      if current_ability.can?(:manage, current_account)
        format.csv do
          send_data Users.generate_csv(@users), filename: "users-#{Time.current.iso8601}.csv", type: 'text/csv'
        end
      end
    end
  end

  def new; end

  def edit; end

  def create
    existing_user = User.accessible_by(current_ability).find_by(email: @user.email)

    if existing_user && !reactivatable?(existing_user)
      @user.errors.add(:email, I18n.t('already_exists'))

      return render turbo_stream: turbo_stream.replace(:modal, template: 'users/new'), status: :unprocessable_content
    end

    # Seats: a free account has one, a paid account its subscription quantity.
    # The check and the save share the account's creation lock so two invites
    # for the last seat cannot both get in; reactivating an archived user
    # fills a seat like a new invite does. Session 7 replaces the paid branch
    # with the proration / pending-invite flow; the free refusal stays.
    saved = Quotas.with_creation_lock(current_account) do
      Quotas.assert_seat_available!(current_account)

      @user = reactivate(existing_user) if existing_user

      @user.password = SecureRandom.hex if @user.password.blank?
      @user.role = User::ADMIN_ROLE unless role_valid?(@user.role)
      @user.skip_confirmation!

      @user.save
    end

    if saved
      UserMailer.invitation_email(@user).deliver_later!

      redirect_back fallback_location: settings_users_path, notice: I18n.t('user_has_been_invited')
    else
      render turbo_stream: turbo_stream.replace(:modal, template: 'users/new'), status: :unprocessable_content
    end
  rescue Quotas::SeatLimitReached => e
    redirect_to settings_users_path, alert: e.localized_message
  end

  def update
    return redirect_to settings_users_path, notice: I18n.t('unable_to_update_user') if Docuseal.demo?

    attrs = user_params.compact_blank
    attrs = attrs.merge(user_params.slice(:archived_at)) if current_ability.can?(:create, @user)

    if params.dig(:user, :account_id).present?
      account = Account.accessible_by(current_ability).find(params.dig(:user, :account_id))

      authorize!(:manage, account)

      @user.account = account
    end

    self_excluded = %i[password otp_required_for_login role archived_at]

    if @user.update(attrs.except(*(current_user == @user ? self_excluded : %i[password])))
      if @user.try(:pending_reconfirmation?) && @user.previous_changes.key?(:unconfirmed_email)
        SendConfirmationInstructionsJob.perform_async('user_id' => @user.id)

        redirect_back fallback_location: settings_users_path,
                      notice: I18n.t('a_confirmation_email_has_been_sent_to_the_new_email_address')
      else
        redirect_back fallback_location: settings_users_path, notice: I18n.t('user_has_been_updated')
      end
    else
      render turbo_stream: turbo_stream.replace(:modal, template: 'users/edit'), status: :unprocessable_content
    end
  end

  def destroy
    if Docuseal.demo? || @user.id == current_user.id
      return redirect_to settings_users_path, notice: I18n.t('unable_to_remove_user')
    end

    @user.update!(archived_at: Time.current)

    redirect_back fallback_location: settings_users_path, notice: I18n.t('user_has_been_removed')
  end

  private

  # User management (listing, inviting, editing, removing users) is admin-only.
  # Editors/viewers manage their own profile via ProfileController instead.
  def authorize_account_management!
    authorize!(:manage, current_account)
  end

  def role_valid?(role)
    User::ROLES.include?(role)
  end

  def reactivatable?(existing_user)
    existing_user.archived_at? &&
      current_ability.can?(:manage, existing_user) && current_ability.can?(:manage, @user.account)
  end

  def reactivate(existing_user)
    existing_user.assign_attributes(@user.slice(:first_name, :last_name, :role, :account_id))
    existing_user.archived_at = nil

    existing_user
  end

  def build_user
    @user = current_account.users.new(user_params)
  end

  def user_params
    if params.key?(:user)
      permitted_params = %i[email first_name last_name password archived_at otp_required_for_login]

      permitted_params << :role if role_valid?(params.dig(:user, :role))

      params.require(:user).permit(permitted_params)
    else
      {}
    end
  end
end
