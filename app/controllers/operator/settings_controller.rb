# frozen_string_literal: true

module Operator
  # The one platform-wide setting the console owns — where automatic operator
  # alerts are sent — and a read-only picture of how this deployment is
  # actually configured.
  #
  # Nothing secret is ever rendered here. Stripe's keys are reported as
  # present/absent and right-shaped/wrong-shaped, never read out; the Postmark
  # webhook is reported as configured or not; the platform signing certificate
  # is reported by its fingerprint, which is the public half by definition.
  # A console page that prints a key is a key in a screenshot.
  class SettingsController < BaseController
    # The address every automatic alert goes to. Stored as an AccountConfig
    # row on the operator account, read by OperatorAlert.address, and blank
    # means "use the support mailbox".
    EMAIL_KEY = OperatorAlert::EMAIL_KEY

    # The same shape the rest of the app demands of an address.
    EMAIL_FORMAT = AccountInvite::EMAIL_FORMAT

    rescue_from Refused, with: :refused

    def show
      load_settings
    end

    def update
      reason = required_reason
      address = submitted_address!
      before = OperatorConfigs.fetch(EMAIL_KEY).presence

      ApplicationRecord.transaction do
        # Clearing removes the row rather than blanking it: the config column
        # is NOT NULL, and "no address set" has one representation.
        address.blank? ? OperatorConfigs.clear!(EMAIL_KEY) : OperatorConfigs.set!(EMAIL_KEY, address)

        OperatorEvents.record!(operator: true_user, action: 'settings.update', reason:,
                               details: { key: EMAIL_KEY, before:, after: address.presence }, request:)
      end

      redirect_to operator_settings_path, notice: t('operator_notice_settings_saved')
    rescue OperatorConfigs::MissingOperatorAccountError
      raise Refused, t('operator_refused_no_operator_account')
    end

    private

    def load_settings
      @alert_email = OperatorConfigs.fetch(EMAIL_KEY).presence
      @alert_fallback = Docuseal::SUPPORT_EMAIL
      @alert_effective = OperatorAlert.address
      @registration_enabled = Docuseal.registration_enabled?
      @billing_enabled = Docuseal.billing_enabled?
      @stripe_status = StripeBilling.config_status
      @stripe_mode = StripeBilling.key_mode
      @postmark_configured = PostmarkWebhooks.configured?
      @certificate_fingerprint = certificate_fingerprint
      @timeserver_url = Docuseal::TIMESERVER_URL.presence
    end

    # The same value `rake operator:platform_cert:fingerprint` prints, read
    # through the same helper. A deployment that has not been seeded yet has
    # no certificate and no operator account to hang one on — a fact to show,
    # not an exception to raise on a settings page.
    def certificate_fingerprint
      PlatformCertificate.fingerprint
    rescue PlatformCertificate::MissingCertificateError, OperatorConfigs::MissingOperatorAccountError
      nil
    end

    # Blank clears the row and puts the support mailbox back; anything else
    # has to look like an address, because the alerts that go to it are the
    # only warning a person gets.
    def submitted_address!
      address = params[:operator_alert_email].to_s.strip

      return '' if address.blank?

      raise Refused, t('operator_refused_alert_email_invalid') unless EMAIL_FORMAT.match?(address)

      address
    end

    def refused(error)
      refused_page(error, :show) { load_settings }
    end
  end
end
