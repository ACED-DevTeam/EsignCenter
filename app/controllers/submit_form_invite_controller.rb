# frozen_string_literal: true

class SubmitFormInviteController < ApplicationController
  rescue_from EsignConsent::ConsentRequiredError do
    render json: { error: 'esign_consent_required' }, status: :unprocessable_content
  end

  rescue_from EsignConsent::StaleVersionError do
    render json: { error: 'esign_consent_version_stale' }, status: :unprocessable_content
  end

  # The invite request carries the same consent the form step does, so it has
  # to resolve the same locale the signing page rendered the disclosure under
  # (SubmitFormController does this for show/update) — otherwise the server's
  # answer and the page's would differ and EsignConsent.record! would refuse a
  # perfectly honest consent from a non-English signer.
  around_action :with_browser_locale, only: :create
  skip_before_action :authenticate_user!
  skip_authorization_check

  def create
    @submitter = Submitter.find_by!(slug: params[:submit_form_slug])

    return head :unprocessable_content unless can_invite?(@submitter)

    invite_submitters = filter_invite_submitters(@submitter, 'invite_by_uuid')
    optional_invite_submitters = filter_invite_submitters(@submitter, 'optional_invite_by_uuid')

    ApplicationRecord.transaction do
      (invite_submitters + optional_invite_submitters).each do |item|
        attrs = submitters_attributes.find { |e| e[:uuid] == item['uuid'] }

        next unless attrs
        next if attrs[:email].blank?

        email = Submissions.normalize_email(attrs[:email])

        @submitter.submission.submitters.create!(uuid: attrs[:uuid], email:, account_id: @submitter.account_id)

        SubmissionEvents.create_with_tracking_data(@submitter, 'invite_party', request, { uuid: @submitter.uuid })
      end

      @submitter.submission.update!(submitters_order: :preserved)
    end

    @submitter.submission.submitters.reload

    if invite_submitters.all? { |s| @submitter.submission.submitters.any? { |e| e.uuid == s['uuid'] } }
      complete_submitter!(@submitter)

      head :ok
    else
      head :unprocessable_content
    end
  end

  private

  # The invite form is the last request of an invite-then-complete signing, so
  # it carries the signer's ESIGN consent the same way a form step does.
  def complete_submitter!(submitter)
    consent_params = params.permit(:esign_consent, :esign_consent_version, :esign_consent_locale,
                                   :esign_consent_locale_token, :esign_consent_pdf_opened,
                                   :esign_consent_sender_digest).to_h

    Submitters::SubmitValues.call(submitter,
                                  ActionController::Parameters.new(completed: 'true', **consent_params),
                                  request)
  end

  # An archived account is gone, and nothing more is written into it — not
  # even by a signer with a link in hand (Phase A policy, the same refusal
  # the decline and delegate doors make). Suspension is deliberately NOT
  # here: a signer part-way through a document still finishes it.
  def can_invite?(submitter)
    !submitter.declined_at? &&
      !submitter.completed_at? &&
      !submitter.submission.archived_at? &&
      !submitter.submission.expired? &&
      !submitter.submission.template&.archived_at? &&
      !submitter.account.archived_at? &&
      Submitters::AuthorizedForForm.call(submitter, current_user, request)
  end

  def filter_invite_submitters(submitter, key = 'invite_by_uuid')
    (submitter.submission.template_submitters || submitter.submission.template.submitters).select do |s|
      s[key] == submitter.uuid && submitter.submission.submitters.none? { |e| e.uuid == s['uuid'] }
    end
  end

  def submitters_attributes
    params.require(:submission).permit(submitters: [%i[uuid email]]).fetch(:submitters, [])
  end
end
