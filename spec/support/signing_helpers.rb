# frozen_string_literal: true

# The helpers the three Session-4 golden signing specs (consent_spec,
# platform_certificate_spec, verify_spec) each spelled out identically: how to
# find a submitter's text field, how to complete a submitter the way a real
# signer does, and how to read the signing identity back out of a signed PDF.
module SigningHelpers
  # Link, embed and selfsign submissions copy the template's fields on the
  # first save, so fall back to the template until then.
  def text_field(submitter)
    fields = submitter.submission.template_fields.presence || submitter.submission.template.fields

    fields.find { |f| f['type'] == 'text' && f['submitter_uuid'] == submitter.uuid }
  end

  # The real interactive completion path, consent included (Phase A).
  def complete!(submitter)
    put "/s/#{submitter.slug}", params: { completed: 'true', esign_consent: 'true',
                                          esign_consent_version: EsignConsent::VERSION,
                                          values: { text_field(submitter)['uuid'] => 'Jane' } }

    expect(response).to have_http_status(:ok)

    submitter.reload
  end

  def signer_public_keys(bytes)
    HexaPDF::Document.new(io: StringIO.new(bytes)).signatures.map do |signature|
      signature.signature_handler.signer_certificate.public_key.to_der
    end
  end

  def public_key_of(pem)
    OpenSSL::X509::Certificate.new(pem).public_key.to_der
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end

RSpec.configure do |config|
  config.include SigningHelpers
end
