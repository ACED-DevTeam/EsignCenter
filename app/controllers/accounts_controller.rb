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
  authorize_resource :account, except: %i[destroy cancel_deletion deletion_code]

  # And on top of the ability, the plainest possible statement of who may end
  # the company's account (review batch 2, K8). `:administer` is granted by
  # `admin_abilities`, which every role that is not viewer/editor falls into —
  # the API-only `integration` role and any legacy role included. An API robot
  # holding a session must not be able to delete the company, so the three
  # deletion doors ask for a real, seat-holding administrator as well.
  before_action :require_account_administrator!, only: %i[destroy cancel_deletion deletion_code]
  before_action :refuse_while_impersonating!, only: %i[destroy cancel_deletion deletion_code]

  # Asking for a code sends mail to a real person and resets the guess budget,
  # so the asking is throttled too (review batch 2, P8). Per USER rather than
  # per IP: the mailbox being filled is theirs, and the budget being reset is
  # theirs. Accounts::DeletionCodes has the same limit inside it — this one
  # answers with a page instead of an exception.
  rate_limit(
    to: Accounts::DeletionCodes::MAX_ISSUES,
    within: Accounts::DeletionCodes::ISSUE_WINDOW,
    only: %i[deletion_code],
    by: -> { current_user.id },
    store: RateLimit.store,
    with: -> { redirect_to settings_account_path, alert: I18n.t('too_many_attempts') }
  )

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
    return refuse(I18n.t('account_deletion_not_available')) unless Accounts::Deletion.deletable?(current_account)
    return refuse(I18n.t('account_deletion_confirmation_required')) unless confirmed?
    return refuse(identity_error) unless identity_proved?

    Accounts::Deletion.request!(current_account, requested_by: true_user)

    redirect_to settings_account_path,
                notice: I18n.t('account_deletion_scheduled_notice',
                               date: Accounts::Deletion.format_date(current_account.purge_scheduled_for))
  rescue Accounts::DeletionCodes::TooManyAttempts
    refuse(I18n.t('too_many_attempts'))
  end

  # "Email me a confirmation code": the second way to prove it is them, for
  # anybody who signs in with Google and has no password they know (K9).
  def deletion_code
    return refuse(I18n.t('account_deletion_not_available')) unless Accounts::Deletion.deletable?(current_account)

    code = Accounts::DeletionCodes.issue!(current_account, true_user)

    AccountMailer.deletion_code(true_user, code:).deliver_later!

    redirect_to settings_account_path,
                notice: I18n.t('account_deletion_code_sent', email: true_user.email)
  rescue Accounts::DeletionCodes::TooManyAttempts
    refuse(I18n.t('too_many_attempts'))
  end

  # "Cancel deletion", from the settings card or the banner on every page.
  def cancel_deletion
    return refuse(I18n.t('account_deletion_not_scheduled')) unless current_account.pending_deletion?

    # False means the purge has already claimed the account: it is being
    # emptied right now, or died part-way and will be resumed. Telling
    # somebody their deletion was cancelled at that moment would be the worst
    # lie this feature could tell (review batch 2, P1).
    return refuse(I18n.t('account_deletion_already_started')) unless Accounts::Deletion.cancel!(current_account)

    redirect_to settings_account_path, notice: I18n.t('account_deletion_cancelled_notice')
  end

  private

  # The ability first — it is what a suspended or parked person loses — and
  # then the two things the ability cannot say: this has to be somebody whose
  # role is literally `admin`, and who still holds a seat. Anything else is
  # refused the way CanCan refuses, so the rescue_from at the top of the app
  # turns it into the ordinary "not authorized" page.
  def require_account_administrator!
    authorize!(:administer, current_account)

    return if true_user.role == User::ADMIN_ROLE && !true_user.read_only? &&
              current_user.role == User::ADMIN_ROLE && !current_user.read_only?

    raise CanCan::AccessDenied
  end

  # Nobody deletes an account they are only VISITING (review batch 2, P6).
  # An operator impersonating a customer administrator is signed in as
  # themselves — `true_user` is the operator, and it is the operator's
  # password or mailbox that would confirm it. Ending a customer's company on
  # the operator's own credentials is exactly what Session 8's impersonation
  # contract forbids, and the three deletion doors are the ones where it
  # cannot be undone. A support agent who genuinely has to do this has
  # `rake accounts:purge` and `accounts:cancel_deletion`, which leave a
  # console record.
  def refuse_while_impersonating!
    return if true_user == current_user

    redirect_to settings_account_path, alert: I18n.t('account_deletion_not_while_impersonating')
  end

  def refuse(message)
    redirect_to settings_account_path, alert: message
  end

  # The typed confirmation. A checkbox on its own is a reflex; this one sits
  # under a list of everything that is about to happen.
  def confirmed?
    ActiveModel::Type::Boolean.new.cast(params[:confirm]) == true
  end

  # Prove it is really them, at the keyboard, right now — one of two ways,
  # and whichever one they actually filled in (review batch 2, K9).
  #
  # Most people type their password. Somebody who only ever signed in with
  # Google has a password, technically — a random token OmniAuth generated
  # that nobody has ever seen — so asking them for it is asking for something
  # that does not exist. They ask for a code instead and prove they still
  # control the mailbox, which is a real second factor. The branch this
  # replaces asked them to retype the account name, which was printed on the
  # screen above the field.
  def identity_proved?
    return password_proved? if params[:password].present?
    return Accounts::DeletionCodes.verify!(current_account, true_user, params[:confirmation_code]) if code_given?

    false
  end

  # Through Devise's own gate rather than `valid_password?` alone (K12).
  # `valid_for_authentication?` is what counts a failed attempt and locks the
  # account after too many: without it this door was an unthrottled password
  # oracle that left no trace on the user row at all.
  def password_proved?
    true_user.valid_for_authentication? { true_user.valid_password?(params[:password].to_s) }
  end

  def code_given?
    params[:confirmation_code].present?
  end

  def identity_error
    return I18n.t('account_deletion_wrong_code') if code_given?
    return I18n.t('account_deletion_wrong_password') if params[:password].present?

    I18n.t('account_deletion_proof_required')
  end

  def load_account
    @account = current_account
  end

  def account_params
    params.require(:account).permit(:name, :timezone, :locale)
  end
end
