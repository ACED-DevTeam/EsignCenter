# frozen_string_literal: true

class SubmitFormDelegateController < ApplicationController
  skip_before_action :authenticate_user!
  skip_authorization_check

  before_action :load_submitter

  def create
    return redirect_to submit_form_path(@submitter.slug) unless delegatable?

    @submitter.account.account_configs.find_by!(key: AccountConfig::ALLOW_TO_DELEGATE_KEY, value: true)

    email = Submissions.normalize_email(params[:email])

    return redirect_to submit_form_path(@submitter.slug) if email.blank?

    # Delegating emails a fresh link to the new address, so a signer could
    # otherwise hand the document round a loop of addresses for ever: it is
    # a resend like any other (Submitters::ResendGuard), counted on this
    # signer whatever address it goes to.
    Submitters::ResendGuard.claim!(@submitter)

    old_slug = @submitter.slug

    ApplicationRecord.transaction do
      @submitter.submitter_versions.create!(slug: old_slug, email: @submitter.email,
                                            name: @submitter.name, phone: @submitter.phone)

      SubmissionEvents.create_with_tracking_data(@submitter, 'delegate_form', request,
                                                 { old_email: @submitter.email, email: })

      @submitter.update!(email:, phone: nil, name: nil, slug: SecureRandom.base58(14))
    end

    SendSubmitterInvitationEmailJob.perform_async('submitter_id' => @submitter.id)

    redirect_to submit_form_delegated_path(old_slug)
  rescue Quotas::LimitReached
    render 'submit_form/delegation_unavailable', layout: 'form', status: :too_many_requests
  end

  private

  def delegatable?
    return false if @submitter.declined_at? || @submitter.completed_at? || @submitter.account.archived_at?

    submission = @submitter.submission

    return false if submission.archived_at? || submission.expired? || submission.template&.archived_at?

    Submitters::AuthorizedForForm.call(@submitter, current_user, request)
  end

  def load_submitter
    @submitter = Submitter.find_by!(slug: params[:submit_form_slug])
  end
end
