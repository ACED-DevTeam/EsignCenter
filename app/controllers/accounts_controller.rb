# frozen_string_literal: true

class AccountsController < ApplicationController
  LOCALE_OPTIONS = {
    'en-US' => 'English (United States)',
    'en-GB' => 'English (United Kingdom)',
    'fr-FR' => 'Français',
    'es-ES' => 'Español',
    'pt-PT' => 'Português',
    'de-DE' => 'Deutsch',
    'it-IT' => 'Italiano',
    'nl-NL' => 'Nederlands'
  }.freeze

  before_action :load_account
  # The two deletion doors authorize themselves, and deliberately not with
  # `:destroy` on the account. An account pending deletion — and an account
  # suspended for an unpaid card — is READ-ONLY, which takes `:manage, Account`
  # (and with it `:destroy`) away from everybody. But asking to be deleted is
  # how a customer LEAVES, and cancelling that request is how they come back:
  # a customer whose card failed must still be able to walk away rather than
  # being held on a plan they cannot pay for. Both doors ask for `:administer`
  # instead — the narrow admin-only ability the read-only layer keeps
  # (lib/ability.rb) — and every other refusal below is spelled out in code.
  authorize_resource :account, except: %i[destroy cancel_deletion]

  def show; end

  def update
    current_account.update!(account_params)

    with_locale do
      redirect_to settings_account_path, notice: I18n.t('account_information_has_been_updated')
    end
  rescue ActiveRecord::RecordInvalid
    render :show, status: :unprocessable_content
  end

  # "Delete my account": the start of the 90-day window, not the deletion.
  def destroy
    authorize!(:administer, current_account)

    return refuse(I18n.t('account_deletion_not_available')) unless Accounts::Deletion.deletable?(current_account)
    return refuse(I18n.t('account_deletion_confirmation_required')) unless confirmed?
    return refuse(identity_error) unless identity_proved?

    Accounts::Deletion.request!(current_account, requested_by: true_user)

    redirect_to settings_account_path,
                notice: I18n.t('account_deletion_scheduled_notice',
                               date: Accounts::Deletion.format_date(current_account.purge_scheduled_for))
  end

  # "Cancel deletion", from the settings card or the banner on every page.
  def cancel_deletion
    authorize!(:administer, current_account)

    return refuse(I18n.t('account_deletion_not_scheduled')) unless current_account.pending_deletion?

    Accounts::Deletion.cancel!(current_account)

    redirect_to settings_account_path, notice: I18n.t('account_deletion_cancelled_notice')
  end

  private

  def refuse(message)
    redirect_to settings_account_path, alert: message
  end

  # The typed confirmation. A checkbox on its own is a reflex; this one sits
  # under a list of everything that is about to happen.
  def confirmed?
    ActiveModel::Type::Boolean.new.cast(params[:confirm]) == true
  end

  # Prove it is really them, at the keyboard, right now.
  #
  # Almost everybody has a password and types it. Somebody who only ever
  # signed in with Google has no password to type — `valid_password?` would
  # refuse them forever — so they type the account's name instead. It is a
  # weaker proof and it is the honest one available: they are already signed
  # in through Google, and the name is on the screen above the field, so this
  # is a deliberate-action check rather than a second factor. The UI says so.
  def identity_proved?
    return true_user.valid_password?(params[:password].to_s) if password_holder?

    params[:account_name].to_s.strip.casecmp(current_account.name.to_s.strip).zero?
  end

  def identity_error
    password_holder? ? I18n.t('account_deletion_wrong_password') : I18n.t('account_deletion_wrong_account_name')
  end

  def password_holder?
    true_user.encrypted_password.present?
  end

  def load_account
    @account = current_account
  end

  def account_params
    params.require(:account).permit(:name, :timezone, :locale)
  end
end
