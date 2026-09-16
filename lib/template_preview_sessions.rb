# frozen_string_literal: true

# Stateless, read-only preview of a template's signing form.
#
# A preview session is nothing but a signed, expiring token: no database row is
# created, nothing is persisted, and the token itself carries everything the
# public preview page needs (which template, which account, which origin may
# frame it, and the optional dummy values to paint into the form).
module TemplatePreviewSessions
  DEFAULT_EXPIRES_IN = 2.hours
  MAX_EXPIRES_IN = 24.hours
  MESSAGE_VERIFIER_PURPOSE = 'template_preview'

  module_function

  def verifier
    Rails.application.message_verifier(MESSAGE_VERIFIER_PURPOSE)
  end

  def generate_token(template_id:, account_id:, origin:, values:, expires_in:)
    verifier.generate(
      { 'template_id' => template_id, 'account_id' => account_id, 'origin' => origin, 'values' => values },
      expires_in:
    )
  end

  # Returns nil for a tampered, unparseable or expired token — the caller turns
  # that into a 404 so a bad token never reveals whether the template exists.
  def read_token(token)
    payload = verifier.verified(token.to_s)

    return unless payload.is_a?(Hash)

    payload.with_indifferent_access
  rescue StandardError
    nil
  end
end
