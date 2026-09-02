# frozen_string_literal: true

# The public "is this PDF genuine?" page. No login, no setup redirect: anyone
# holding a PDF can upload it and learn only whether EsignCenter signed those
# exact bytes, on which day and by how many signers (docs/verify.md).
#
# Never renders who signed: no names, emails, certificate subjects, signing
# reasons or times of day reach the page.
class VerifyController < ApplicationController
  layout 'form'

  MAX_FILE_SIZE = 25.megabytes
  MINUTE_LIMIT = 10
  HOUR_LIMIT = 100

  RESULT_STATES = %w[verified not_on_record not_verified].freeze

  skip_before_action :maybe_redirect_to_setup
  skip_before_action :authenticate_user!
  skip_authorization_check

  around_action :with_browser_locale

  def show; end

  def create
    rate_limit!

    # Refuse an oversized body from its declared length, before Rack parses
    # the multipart upload into a tempfile.
    return render_error(:file_too_large, :content_too_large) if request.content_length.to_i > MAX_FILE_SIZE

    file = params[:file]

    return render_error(:no_file, :unprocessable_content) unless file.respond_to?(:read) && file.respond_to?(:size)
    return render_error(:file_too_large, :content_too_large) if file.size > MAX_FILE_SIZE
    return render_error(:not_a_pdf, :unprocessable_content) unless pdf?(file)

    file.rewind
    bytes = file.read

    pdf = HexaPDF::Document.new(io: StringIO.new(bytes))
    record = VerifiedDocument.find_by(sha256: Digest::SHA256.hexdigest(bytes))

    @result = build_result(record, pdf)

    render :show
  rescue RateLimit::LimitApproached
    render_error(:too_many_requests, :too_many_requests)
  rescue HexaPDF::Error
    render_error(:invalid_pdf, :unprocessable_content)
  end

  private

  def rate_limit!
    RateLimit.call("verify-minute-#{request.remote_ip}", limit: MINUTE_LIMIT, ttl: 1.minute)
    RateLimit.call("verify-hour-#{request.remote_ip}", limit: HOUR_LIMIT, ttl: 1.hour)
  end

  def pdf?(file)
    file.rewind

    Marcel::MimeType.for(file) == 'application/pdf'
  end

  # verified: our record of the bytes exists AND a signature we made checks
  # out; not_on_record: our signature but bytes we never recorded (changed
  # after signing, or signed before the record existed); not_verified: none.
  def build_result(record, pdf)
    trusted = Accounts.platform_verification_certs
    signed_by_us = pdf.signatures.any? { |signature| trusted_signature?(signature, trusted) }

    if record && signed_by_us
      { state: 'verified', signed_on: record.signed_at.utc.to_date, signers_count: record.signers_count }
    elsif signed_by_us
      { state: 'not_on_record' }
    else
      { state: 'not_verified' }
    end
  end

  # A signature counts only when HexaPDF reports no error-level finding
  # (integrity, byte range, chain) AND the signer certificate's public key is
  # one of ours — the chain check alone would accept any certificate the
  # trust set happens to vouch for.
  def trusted_signature?(signature, trusted)
    return false unless signature.verify(trusted_certs: trusted).success?

    signer_key = signature.signature_handler.signer_certificate.public_key.to_der

    trusted.any? { |certificate| certificate.public_key.to_der == signer_key }
  rescue HexaPDF::Error, OpenSSL::OpenSSLError, NoMethodError
    false
  end

  def render_error(error, status)
    @result = { state: 'error', error: error.to_s }

    render :show, status:
  end
end
