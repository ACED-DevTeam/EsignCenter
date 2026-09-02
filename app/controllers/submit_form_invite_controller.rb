# frozen_string_literal: true

class SubmitFormInviteController < ApplicationController
  rescue_from EsignConsent::ConsentRequiredError do
    render json: { error: 'esign_consent_required' }, status: :unprocessable_content
  end

  rescue_from EsignConsent::StaleVersionError do
    render json: { error: 'esign_consent_version_stale' }, status: :unprocessable_content
  end

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
    consent_params = params.permit(:esign_consent, :esign_consent_version).to_h

    Submitters::SubmitValues.call(submitter,
                                  ActionController::Parameters.new(completed: 'true', **consent_params),
                                  request)
  end

  def can_invite?(submitter)
    !submitter.declined_at? &&
      !submitter.completed_at? &&
      !submitter.submission.archived_at? &&
      !submitter.submission.expired? &&
      !submitter.submission.template&.archived_at? &&
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
