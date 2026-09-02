# frozen_string_literal: true

# Every customer account signs with the platform certificate (Session 4), so a
# spec that signs seeds that ONE row instead of a per-account one. The PEMs are
# generated once per process: RSA key generation is slow and the certificate's
# content never matters to the assertions.
module PlatformCertificateHelper
  def self.pems
    @pems ||= GenerateCertificate.call(Docuseal.product_name).transform_values(&:to_pem).stringify_keys
  end

  # The operator account and its platform certificate row, created on demand.
  # Idempotent: calling it twice in one example leaves one row.
  def platform_certificate!
    account = OperatorConfigs.account || create(:account, :operator)

    account.encrypted_configs.find_by(key: EncryptedConfig::PLATFORM_ESIGN_CERTS_KEY) ||
      create(:encrypted_config, account:, key: EncryptedConfig::PLATFORM_ESIGN_CERTS_KEY,
                                value: PlatformCertificateHelper.pems)
  end

  def platform_certificate_pems
    PlatformCertificateHelper.pems
  end
end

RSpec.configure do |config|
  config.include PlatformCertificateHelper
end
