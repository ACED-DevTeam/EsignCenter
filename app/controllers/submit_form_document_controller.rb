# frozen_string_literal: true

# "View this document as a PDF" beside the ESIGN consent checkbox.
#
# The signing page already renders every page of this document to the person
# holding the link, so serving them the same pages as a PDF file gives away
# nothing new — it lets them prove their device can open a PDF before they
# agree to be sent one, which is what 15 U.S.C. §7001(c) asks of them. The
# slug is the only key, exactly as it is for the signing page itself.
#
# Two gates, both the signing page's own: `AuthorizedForForm` (email and
# share-link 2FA), so a protected document cannot be read around the code, and
# `FormOpen`, so an archived, expired, declined or not-yet-your-turn form
# refuses here exactly as it refuses there.
#
# `allow_to_partial_download = false` is deliberately NOT applied. That
# setting hides the "download what has been signed so far" button, which is
# about handing out a partly-completed document; this door serves the
# unsigned original the signer is already looking at, and the consent gate
# cannot be satisfied without it. Turning it off here would leave those
# accounts' signers unable to agree at all.
class SubmitFormDocumentController < ApplicationController
  skip_before_action :authenticate_user!
  skip_authorization_check

  # Merging documents costs real work per request, and the slug is public to
  # whoever holds the link. A signer needs the PDF once or twice; 20 in an
  # hour is generous for a person and cheap to refuse for a script.
  REQUESTS_PER_SLUG_PER_HOUR = 20

  rescue_from RateLimit::LimitApproached do
    render plain: I18n.t('esign_consent_document_too_many_requests'), status: :too_many_requests
  end

  def show
    @submitter = Submitter.find_by(slug: params[:submit_form_slug])

    return head :not_found if @submitter.nil?
    return head :not_found unless Submitters::AuthorizedForForm.call(@submitter, current_user, request)
    return head :not_found unless Submitters::FormOpen.call(@submitter)

    RateLimit.call("esign-consent-document-#{@submitter.slug}", limit: REQUESTS_PER_SLUG_PER_HOUR, ttl: 1.hour)

    submission = @submitter.submission
    attachments = Submissions::OriginalDocumentPdf.attachments_for(submission)

    return head :not_found if attachments.blank?

    send_data Submissions::OriginalDocumentPdf.call(attachments),
              filename: "#{submission.name || submission.template&.name || I18n.t('document')}.pdf",
              type: 'application/pdf',
              disposition: 'inline'
  end
end
