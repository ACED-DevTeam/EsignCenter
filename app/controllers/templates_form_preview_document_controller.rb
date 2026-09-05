# frozen_string_literal: true

# The form preview's copy of the signer's "View this document as a PDF" link.
#
# The preview (the dry run in the builder) shows senders exactly what signers
# see, consent checkbox and all, but its signer record is never saved — so the
# signer-scoped door has no slug to answer for. This one answers for the
# template instead, to the sender who may already read it. There is no form
# state to be open or closed here and no slug to rate-limit: the reader is a
# signed-in user of the account, gated by the ordinary template ability.
class TemplatesFormPreviewDocumentController < ApplicationController
  load_and_authorize_resource :template

  def show
    attachments = Submissions::OriginalDocumentPdf.template_attachments(@template)

    return head :not_found if attachments.blank?

    if (blob = Submissions::OriginalDocumentPdf.single_pdf(attachments)&.blob)
      return redirect_to blobs_proxy_path(signed_uuid: blob.signed_uuid(expires_at: 5.minutes.from_now.to_i),
                                          filename: blob.filename, disposition: 'inline'),
                         allow_other_host: false
    end

    send_data Submissions::OriginalDocumentPdf.call(attachments),
              filename: "#{@template.name}.pdf",
              type: 'application/pdf',
              disposition: 'inline'
  end
end
