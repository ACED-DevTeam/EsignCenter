# frozen_string_literal: true

# "View this document as a PDF" beside the ESIGN consent checkbox.
#
# The signing page already renders every page of this document to the person
# holding the link, so serving them the same pages as a PDF file gives away
# nothing new — it lets them prove their device can open a PDF before they
# agree to be sent one, which is what 15 U.S.C. §7001(c) asks of them. The
# slug is the only key, exactly as it is for the signing page itself, and the
# same email/link 2FA gate the form passes is applied here so a protected
# document cannot be read around the code.
class SubmitFormDocumentController < ApplicationController
  skip_before_action :authenticate_user!
  skip_authorization_check

  def show
    @submitter = Submitter.find_by(slug: params[:submit_form_slug])

    return head :not_found if @submitter.nil?

    submission = @submitter.submission

    return head :not_found unless Submitters::AuthorizedForForm.call(@submitter, current_user, request)
    return head :not_found if submission.archived_at? || submission.expired? ||
                              submission.template&.archived_at?

    attachments = submission.schema_documents.preload(:blob).to_a

    return head :not_found if attachments.blank?

    send_data Submissions::OriginalDocumentPdf.call(attachments),
              filename: "#{submission.name || submission.template&.name || I18n.t('document')}.pdf",
              type: 'application/pdf',
              disposition: 'inline'
  end
end
