# frozen_string_literal: true

RSpec.describe Entitlements, type: :lib do
  let(:free_account) { create(:account) }
  let(:paid_account) { create(:account, :paid) }
  let(:business_account) do
    create(:account, :paid).tap { |account| account.account_subscription.update!(plan: Plans::BUSINESS) }
  end
  let(:internal_account) { create(:account, :internal) }

  it 'mirrors the entitlement matrix: paid-only rows and hidden-for-everyone rows' do
    expect(described_class::PAID_ONLY).to eq(
      %i[api mcp webhooks signing_sessions embed conditional_logic reminders
         branding_removal custom_email_templates account_smtp bcc delivery_tracking]
    )
    expect(described_class::HIDDEN).to eq(%i[sms bulk_send saml_sso formulas])
    expect(described_class.paid_only_rows).to eq(described_class::PAID_ONLY)
    expect(described_class::REFUSAL_MESSAGE).to eq('This feature requires a paid plan')
    expect(described_class::UNAVAILABLE_MESSAGE).to eq('This feature is not available')
  end

  describe '.allowed?' do
    it 'refuses every paid-only feature to a free account and grants it to Paid, Business and internal accounts' do
      described_class::PAID_ONLY.each do |feature|
        expect(described_class.allowed?(free_account, feature)).to be(false), feature.to_s
        expect(described_class.allowed?(paid_account, feature)).to be(true), feature.to_s
        expect(described_class.allowed?(business_account, feature)).to be(true), feature.to_s
        expect(described_class.allowed?(internal_account, feature)).to be(true), feature.to_s
      end
    end

    it 'never grants a hidden feature, not even to internal or operator accounts' do
      operator_account = create(:account, :operator)

      described_class::HIDDEN.each do |feature|
        [free_account, paid_account, business_account, internal_account, operator_account].each do |account|
          expect(described_class.allowed?(account, feature)).to be(false), "#{feature} for #{account.account_kind}"
        end
      end
    end

    it 'accepts the feature as a string too' do
      expect(described_class.allowed?(paid_account, 'api')).to be(true)
    end

    it 'raises on an unknown feature so a typo can never silently allow or refuse' do
      expect { described_class.allowed?(paid_account, :apis) }.to raise_error(ArgumentError, /apis/)
      expect { described_class.allowed?(internal_account, :everything) }.to raise_error(ArgumentError)
    end

    it 'treats a missing account as free' do
      expect(described_class.allowed?(nil, :api)).to be(false)
    end
  end

  describe '.require!' do
    it 'raises UpgradeRequired naming the feature for a free account and returns quietly otherwise' do
      expect { described_class.require!(free_account, :webhooks) }
        .to raise_error(described_class::UpgradeRequired) { |error| expect(error.feature).to eq(:webhooks) }

      expect { described_class.require!(paid_account, :webhooks) }.not_to raise_error
      expect { described_class.require!(internal_account, :webhooks) }.not_to raise_error
    end

    it 'raises for a hidden feature regardless of plan' do
      expect { described_class.require!(internal_account, :formulas) }.to raise_error(described_class::UpgradeRequired)
    end
  end

  describe '.allowed_features' do
    it 'is the whole paid-only list for paid and internal accounts and empty for free' do
      expect(described_class.allowed_features(paid_account)).to eq(described_class::PAID_ONLY)
      expect(described_class.allowed_features(internal_account)).to eq(described_class::PAID_ONLY)
      expect(described_class.allowed_features(free_account)).to eq([])
    end
  end

  describe '.require_for_account_config!' do
    it 'maps the gated account-config keys to their matrix rows' do
      expect(described_class::ACCOUNT_CONFIG_FEATURES).to eq(
        AccountConfig::SUBMITTER_REMINDERS => :reminders,
        AccountConfig::BCC_EMAILS => :bcc,
        AccountConfig::REMOVE_BRANDING_KEY => :branding_removal,
        AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY => :custom_email_templates,
        AccountConfig::SUBMITTER_INVITATION_REMINDER_EMAIL_KEY => :custom_email_templates,
        AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY => :custom_email_templates,
        AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY => :custom_email_templates
      )
    end

    it 'refuses a non-blank value for a free account and lets paid and internal through' do
      expect { described_class.require_for_account_config!(free_account, AccountConfig::BCC_EMAILS, 'a@b.com') }
        .to raise_error(described_class::UpgradeRequired)
      expect { described_class.require_for_account_config!(paid_account, AccountConfig::BCC_EMAILS, 'a@b.com') }
        .not_to raise_error
      expect { described_class.require_for_account_config!(internal_account, AccountConfig::BCC_EMAILS, 'a@b.com') }
        .not_to raise_error
    end

    it 'always allows clearing: blank, false, or a hash of blanks' do
      key = AccountConfig::SUBMITTER_REMINDERS

      expect { described_class.require_for_account_config!(free_account, key, nil) }.not_to raise_error
      expect { described_class.require_for_account_config!(free_account, key, '') }.not_to raise_error
      expect { described_class.require_for_account_config!(free_account, key, { 'first_duration' => '' }) }
        .not_to raise_error
      expect { described_class.require_for_account_config!(free_account, AccountConfig::REMOVE_BRANDING_KEY, false) }
        .not_to raise_error

      expect { described_class.require_for_account_config!(free_account, key, { 'first_duration' => 'two_days' }) }
        .to raise_error(described_class::UpgradeRequired)
      expect { described_class.require_for_account_config!(free_account, AccountConfig::REMOVE_BRANDING_KEY, true) }
        .to raise_error(described_class::UpgradeRequired)
    end

    it 'ignores keys that are not gated' do
      expect { described_class.require_for_account_config!(free_account, AccountConfig::FORM_COMPLETED_BUTTON_KEY, 'x') }
        .not_to raise_error
    end
  end

  describe 'refusal copy' do
    it 'has the HTML refusal strings in every declared locale' do
      I18n.available_locales.each do |locale|
        expect(I18n.t('this_feature_requires_a_paid_plan', locale:, raise: true)).to be_present, locale.to_s
        expect(I18n.t('this_feature_is_not_available', locale:, raise: true)).to be_present, locale.to_s
      end
    end

    it 'never promises an upgrade for a hidden feature' do
      expect(described_class.refusal_message(:webhooks)).to eq(described_class::REFUSAL_MESSAGE)
      expect(described_class.refusal_message(:sms)).to eq(described_class::UNAVAILABLE_MESSAGE)
      expect(described_class.refusal_alert(:webhooks)).to eq(I18n.t('this_feature_requires_a_paid_plan'))
      expect(described_class.refusal_alert(:formulas)).to eq(I18n.t('this_feature_is_not_available'))
    end
  end
end
