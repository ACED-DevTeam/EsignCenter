# frozen_string_literal: true

class StartFormEmail2faSendController < ApplicationController
  include SenderViewing
  include SharedFormSource

  around_action :with_browser_locale

  skip_before_action :authenticate_user!
  skip_authorization_check

  def create
    @template = Template.find_by!(slug: params[:slug])

    set_share_embed_frame_headers

    # Revoking a link has to actually revoke it. An owner who switches sharing
    # off, or archives the template, believes the URL is dead — but this
    # endpoint answers any slug, so without this it would still put a code in
    # an arbitrary inbox on that account's behalf. The start form gives both
    # of those a single answer, the form page itself (`completed`'s
    # `!shared_link? || archived_at?` redirect, and `authorize_start!`'s on the
    # PUT), so this door gives the same one instead of an email.
    #
    # It runs first, before everything below, on purpose:
    #   - before assert_documents_ready!, because the start form explains a
    #     still-converting document only to a visitor allowed to open the
    #     template at all (refuse_unready_documents! returns unless the link is
    #     shared);
    #   - before the shared_link_2fa branch, because a closed link is closed
    #     whatever its preferences ask for;
    #   - before the pause check, because `show` skips that check on an
    #     archived template — an archived slug must not be answered here with a
    #     paused message it would never get there.
    return redirect_to start_form_path(@template.slug) if link_revoked?

    return if refuse_unentitled_embed!

    Templates.assert_documents_ready!(@template)

    # A code only for a link that actually asks for one. The start form sends
    # one from a single branch — preferences['shared_link_2fa'] == true — and
    # this endpoint exists to resend what that branch sent, so any other
    # template's slug gets its form back instead of an email its owner never
    # asked us to put in someone's inbox.
    return redirect_to start_form_path(@template.slug) unless @template.preferences['shared_link_2fa'] == true

    # No verification code for a form that cannot be started right now.
    if (reason = Quotas.share_link_paused?(@template.account, source: shared_form_source))
      notify_api_share_pause(reason)

      return render json: { error: pause_error_message(reason) }, status: :unprocessable_content
    end

    @submitter = @template.submissions.new(account_id: @template.account_id)
                          .submitters.new(**submitter_params, account_id: @template.account_id)

    Submitters.send_shared_link_email_verification_code(@submitter, request:)

    redir_params = { notice: I18n.t(:code_has_been_resent) } if params[:resend]

    redirect_to verification_path,
                **redir_params
  rescue Submitters::UnableToSendCode => e
    redirect_to verification_path,
                alert: e.message
  rescue Templates::DocumentsNotReady => e
    redirect_to start_form_path(@template.slug), alert: e.message
  end

  private

  def verification_path
    start_form_path(@template.slug, params: submitter_params.merge(email_verification: true,
                                                                   embed: shared_form_source == 'embed' ? '1' : nil))
  end

  def refuse_unentitled_embed!
    return false unless shared_form_source == 'embed' && !Entitlements.allowed?(@template.account, :embed)

    render json: { error: I18n.t('form_not_accepting_responses') }, status: :forbidden
  end

  # Revoked exactly as the start form counts it: sharing switched off, or the
  # template archived (StartFormController#completed's own
  # `!shared_link? || archived_at?`).
  def link_revoked?
    !@template.shared_link? || @template.archived_at?
  end

  # The same rule the paused page applies (StartFormController#render_paused):
  # the detail — which limit was hit, the number it is, the date it resets, or
  # that deliveries are under review — is the account's own business, so only
  # its signed-in user is told. Anyone else holding the slug gets exactly the
  # generic line the paused page already shows them, so the endpoint's refusal
  # says no more than the page does and needs no new wording in 14 locales.
  def pause_error_message(reason)
    return Quotas.pause_message(@template.account, reason) if sender_viewing?

    I18n.t('form_not_accepting_responses')
  end

  def submitter_params
    params.require(:submitter).permit(:name, :email, :phone)
  end
end
