# frozen_string_literal: true

class SetupController < ApplicationController
  skip_before_action :maybe_redirect_to_setup
  skip_before_action :authenticate_user!
  skip_authorization_check

  before_action :redirect_to_root_if_signed, if: :signed_in?
  before_action :ensure_first_user_not_created!

  def index
    @account = Account.new(account_params.merge(account_kind: Account::INTERNAL_KIND))
    @user = @account.users.new(user_params)
  end

  def create
    @account = Account.new(account_params.merge(account_kind: Account::INTERNAL_KIND))
    @account.timezone = Accounts.normalize_timezone(@account.timezone)
    @user = @account.users.new(user_params)
    @user.skip_confirmation!

    return render :index, status: :unprocessable_content unless @account.valid?

    if @user.save
      @account.encrypted_configs.create!(
        key: EncryptedConfig::ESIGN_CERTS_KEY,
        value: GenerateCertificate.call.transform_values(&:to_pem)
      )

      sign_in(@user)

      redirect_to root_path
    else
      render :index, status: :unprocessable_content
    end
  end

  private

  def user_params
    return {} unless params[:user]

    params.require(:user).permit(:first_name, :last_name, :email, :password)
  end

  def account_params
    return {} unless params[:account]

    params.require(:account).permit(:name, :timezone, :locale)
  end

  def redirect_to_root_if_signed
    redirect_to root_path, notice: I18n.t('you_are_already_signed_in')
  end

  def ensure_first_user_not_created!
    redirect_to new_user_session_path, notice: I18n.t('please_sign_in') if User.exists?
  end
end
