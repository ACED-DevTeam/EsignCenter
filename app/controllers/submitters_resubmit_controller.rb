# frozen_string_literal: true

class SubmittersResubmitController < ApplicationController
  load_and_authorize_resource :submitter, parent: false

  def update
    return redirect_to submit_form_path(slug: @submitter.slug) if @submitter.email != current_user.email

    Templates.assert_documents_ready!(@submitter.template)

    submission = build_copy

    @submitter.submission.submitters.each do |submitter|
      new_submitter = submission.submitters.new(submitter.slice(:uuid, :email, :phone, :name,
                                                                :preferences, :metadata, :account_id))

      next unless submitter.uuid == @submitter.uuid

      assign_submitter_values(new_submitter, submitter)

      @new_submitter ||= new_submitter
    end

    save_under_creation_lock!(submission)

    @submitter.submission.documents_attachments.each do |attachment|
      submission.documents_attachments.create!(uuid: attachment.uuid, blob_id: attachment.blob_id)
    end

    redirect_to submit_form_path(slug: @new_submitter.slug)
  rescue Templates::DocumentsNotReady => e
    redirect_to submit_form_path(slug: @submitter.slug), alert: e.message
  rescue Quotas::LimitReached => e
    redirect_back fallback_location: submit_form_path(slug: @submitter.slug), alert: e.localized_message
  end

  private

  # D73 lineage: the copy joins the family of the document it corrects — the
  # root so every sibling copy can see the others, the origin pointer for the
  # audit trail — so metering counts the family's first completion once
  # (Submissions::Lineage).
  def build_copy
    origin = @submitter.submission

    @submitter.account.submissions.new(created_by_user: current_user,
                                       submitters_order: :preserved,
                                       **Submissions::Lineage.attributes_for_copy(origin),
                                       **origin.slice(:template_fields, :account_id, :name, :template_id,
                                                      :template_schema, :template_submitters, :preferences))
  end

  # A resubmit is a new document to sign: checked and saved under the
  # account's creation lock like every other creation path, with a paid
  # account's velocity signals recorded there too.
  def save_under_creation_lock!(submission)
    Quotas.with_creation_lock(@submitter.account) do
      Quotas.assert_can_create_submissions!(@submitter.account)

      submission.save!

      Quotas.record_paid_signals(@submitter.account)
    end
  end

  def assign_submitter_values(new_submitter, submitter)
    attachments_index = submitter.attachments.index_by(&:uuid)

    # A document nobody has opened yet has no fields of its own yet (they are
    # copied from the template on the first save), so fall back to the
    # template's: an owner resubmitting an unsigned document has no signer
    # values to carry over, but must not meet a 500 either.
    fields = submitter.submission.template_fields || submitter.submission.template&.fields || []

    fields.each do |field|
      next if field['submitter_uuid'] != submitter.uuid
      next if field['default_value'] == '{{date}}'
      next if field['type'] == 'stamp'
      next if field['type'] == 'signature'
      next if field.dig('preferences', 'formula').present?

      value = submitter.values[field['uuid']]

      next if value.blank?

      if field['type'].in?(%w[image file initials])
        Array.wrap(value).each do |attachment_uuid|
          new_submitter.attachments << attachments_index[attachment_uuid].dup
        end
      end

      new_submitter.values[field['uuid']] = value
    end
  end
end
