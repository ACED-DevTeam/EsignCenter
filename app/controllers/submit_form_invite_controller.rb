# frozen_string_literal: true

class SubmitFormInviteController < ApplicationController
  # The request named a party to invite but gave no address for it, so the
  # invite the page promised cannot be made. Raised rather than answered on the
  # spot because everything this request has written so far has to go with it.
  IncompleteInviteError = Class.new(StandardError)

  rescue_from EsignConsent::ConsentRequiredError do
    render json: { error: 'esign_consent_required' }, status: :unprocessable_content
  end

  rescue_from EsignConsent::StaleVersionError do
    render json: { error: 'esign_consent_version_stale' }, status: :unprocessable_content
  end

  # Same three-way answer the form step gives (SubmitFormController): a locale
  # refusal is not a stale disclosure and does not say one was updated.
  rescue_from EsignConsent::LocaleInvalidError do
    render json: { error: 'esign_consent_locale_invalid' }, status: :unprocessable_content
  end

  # Another request for this submission invited the same party first: the
  # unique index on `submitters (submission_id, uuid)` refused the loser and
  # rolled its whole transaction back, so this is the honest answer to
  # "somebody else already did this".
  #
  # THAT index and no other (review 2, N7; review 10, B-F3 — this was the one
  # door of the three left unscoped). Class-wide, it answered every unique-
  # constraint failure this request can trip — a duplicate user, a duplicate
  # search entry, anything a future change adds — with "somebody already
  # invited this party", a sentence that would be false about a bug nobody
  # would ever see. Anything else is re-raised and is a 500, which is what an
  # unexplained conflict is. Said as a `rescue_from` for the same reason
  # SubmitFormController says it that way: the action is about inviting.
  rescue_from ActiveRecord::RecordNotUnique do |e|
    raise e unless e.message.include?(Submitter::ROLE_INDEX)

    render json: { error: 'party_already_invited' }, status: :unprocessable_content
  end

  # This request is a signing page's, so it renders in the signer's language
  # like every other door on the signing flow (SubmitFormController does this
  # for show/update) — refusal messages included. The consent's own language
  # is NOT taken from here: it travels as the signed locale pair the page
  # issued (EsignConsent.record!).
  around_action :with_browser_locale, only: :create
  skip_before_action :authenticate_user!
  skip_authorization_check

  def create
    @submitter = Submitter.find_by!(slug: params[:submit_form_slug])

    # Archived, expired, declined or already finished: there is nothing left to
    # sign, so there is nobody to invite. Said in words the page can show —
    # "Value is invalid" describes none of these (review 2, product 6).
    unless can_invite?(@submitter)
      return render json: { error: 'document_no_longer_accepting' }, status: :unprocessable_content
    end

    invite_submitters = filter_invite_submitters(@submitter, 'invite_by_uuid')
    optional_invite_submitters = filter_invite_submitters(@submitter, 'optional_invite_by_uuid')

    # One request, one transaction: the invited parties, the `invite_party`
    # events and the signer's own completion stand or fall together.
    #
    # They used to be two. The invitees were committed first and the
    # completion — which is what validates the consent and the required
    # fields — ran afterwards, so a refusal (an expired consent version, a
    # locale token that no longer verifies, a required field left empty) was
    # answered 422 with the recipients already added and no way to take them
    # back. Worse, the retry the signer then made with a corrected address was
    # ignored: the role was occupied by the row the refused attempt left
    # behind. Now a refusal leaves the submission exactly as it found it.
    #
    # Inviting a party still happens exactly once, whatever else is in flight:
    # two requests arriving together both pass the "is this uuid already
    # here?" filter, and the unique index on `submitters (submission_id,
    # uuid)` (migration 20260906090000) is what stops them both inserting.
    # The loser raises RecordNotUnique, rolls back and is refused, which is
    # the honest answer to "somebody else already did this".
    #
    # The completion's background work (the completion job, the search
    # reindex, the webhooks) is pushed only once this transaction has
    # committed — Submitters::SubmitValues#enqueue_after_commit — because a
    # job enqueued inside an open transaction can start before the rows it
    # needs exist.
    ApplicationRecord.transaction do
      (invite_submitters + optional_invite_submitters).each do |item|
        attrs = submitters_attributes.find { |e| e[:uuid] == item['uuid'] }

        next unless attrs
        next if attrs[:email].blank?

        email = Submissions.normalize_email(attrs[:email])

        @submitter.submission.submitters.create!(uuid: attrs[:uuid], email:, account_id: @submitter.account_id)

        # The uuid of the party that was just INVITED, not of the signer doing
        # the inviting — the event answers "who was brought in", and the
        # inviter is already the event's own submitter.
        SubmissionEvents.create_with_tracking_data(@submitter, 'invite_party', request, { uuid: attrs[:uuid] })
      end

      @submitter.submission.update!(submitters_order: :preserved)
      @submitter.submission.submitters.reload

      unless invite_submitters.all? { |s| @submitter.submission.submitters.any? { |e| e.uuid == s['uuid'] } }
        raise IncompleteInviteError
      end

      complete_submitter!(@submitter)
    end

    head :ok
  rescue IncompleteInviteError
    head :unprocessable_content
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
