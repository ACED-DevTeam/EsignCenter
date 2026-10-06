# frozen_string_literal: true

# The entitlement matrix (plans/esigncenter-standalone/spec.md, D45) as data.
# Two lists: features a free account does not get, and features nobody gets in
# v1. Every server-side refusal and every `can?(:use, feature)` in a view reads
# from here, so adding a row to the matrix means adding a symbol to a list —
# never a new `if` somewhere else.
module Entitlements
  # Paid and internal accounts get these; free accounts are refused.
  # Delivery tracking is filtered in the modal, audit PDF, API event arrays
  # and export counts; recording for abuse protection applies to every plan.
  PAID_ONLY = %i[api mcp webhooks signing_sessions embed conditional_logic reminders branding_removal
                 custom_email_templates account_smtp bcc delivery_tracking].freeze

  # Hidden for everyone in v1, internal and operator accounts included (D30/D47).
  HIDDEN = %i[sms bulk_send saml_sso formulas].freeze

  FEATURES = (PAID_ONLY + HIDDEN).freeze

  # JSON doors answer with this English constant, like the other API errors
  # ('Not authenticated', 'Account is not active'); HTML controllers use the
  # `this_feature_requires_a_paid_plan` locale key instead.
  REFUSAL_MESSAGE = 'This feature requires a paid plan'

  # Hidden features are not on any plan, so their refusal must not promise an
  # upgrade; JSON doors answer with this constant, HTML controllers with the
  # `this_feature_is_not_available` locale key.
  UNAVAILABLE_MESSAGE = 'This feature is not available'

  # Account configs whose non-blank value switches on a paid-only feature.
  # Clearing a value is always allowed (a downgrade never has to purge, D43).
  ACCOUNT_CONFIG_FEATURES = {
    AccountConfig::SUBMITTER_REMINDERS => :reminders,
    AccountConfig::BCC_EMAILS => :bcc,
    AccountConfig::REMOVE_BRANDING_KEY => :branding_removal,
    AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY => :custom_email_templates,
    AccountConfig::SUBMITTER_INVITATION_REMINDER_EMAIL_KEY => :custom_email_templates,
    AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY => :custom_email_templates,
    AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY => :custom_email_templates
  }.freeze

  class UpgradeRequired < StandardError
    attr_reader :feature

    def initialize(feature)
      @feature = feature

      super("#{REFUSAL_MESSAGE} (#{feature})")
    end
  end

  module_function

  # Hidden features are never allowed; paid-only features follow the plan.
  # An unknown feature is a programming error (typo protection), not a refusal.
  def allowed?(account, feature)
    feature = feature.to_sym

    raise ArgumentError, "Unknown feature: #{feature.inspect}" unless FEATURES.include?(feature)
    return false if HIDDEN.include?(feature)

    Plans.paid_or_better?(account)
  end

  def require!(account, feature)
    raise UpgradeRequired, feature.to_sym unless allowed?(account, feature)
  end

  def hidden?(feature)
    HIDDEN.include?(feature.to_sym)
  end

  # The English refusal for a JSON door, chosen by what was refused.
  def refusal_message(feature)
    hidden?(feature) ? UNAVAILABLE_MESSAGE : REFUSAL_MESSAGE
  end

  # The translated refusal for a browser form, chosen the same way.
  def refusal_alert(feature)
    I18n.t(hidden?(feature) ? 'this_feature_is_not_available' : 'this_feature_requires_a_paid_plan')
  end

  # Every paid-only feature the account may use, resolved with one plan lookup
  # (Ability builds this once per request).
  def allowed_features(account)
    Plans.paid_or_better?(account) ? PAID_ONLY : []
  end

  # The pricing page (Session 9) renders its paid-only rows from this.
  def paid_only_rows
    PAID_ONLY
  end

  # Writing an account config that switches on a paid-only feature requires
  # the feature; clearing it (blank value, or a hash of blanks) never does.
  def require_for_account_config!(account, key, value)
    feature = ACCOUNT_CONFIG_FEATURES[key.to_s]

    return if feature.nil? || clearing?(value)

    require!(account, feature)
  end

  def clearing?(value)
    return true if value.blank?
    return value.each_pair.none? { |_, item| item.present? } if value.respond_to?(:each_pair)

    false
  end
end
