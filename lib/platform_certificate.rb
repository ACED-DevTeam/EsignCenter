# frozen_string_literal: true

# The ONE signing identity every customer account signs with. It lives as an
# encrypted row on the platform-operator account (never on a tenant account),
# is generated once — here and nowhere else — and is exported for offline
# custody with `rake operator:platform_cert:export`.
#
# Internal accounts keep their own certificate rows (Accounts.load_signing_pkcs);
# this module is only about the platform identity.
module PlatformCertificate
  KEY = EncryptedConfig::PLATFORM_ESIGN_CERTS_KEY

  # The offline custody bundle: the signing identity first, then its CA chain,
  # then every private key.
  EXPORT_ORDER = %w[cert sub_ca root_ca key sub_key root_key].freeze

  # A missing operator account is a deployment error, not a signing edge case:
  # signing stops loudly instead of falling back to some other account's cert.
  class MissingOperatorAccountError < OperatorConfigs::MissingOperatorAccountError; end

  module_function

  # The platform certificate row, generating it on first use. Idempotent under
  # a race: the unique index on (account_id, key) decides, and the loser
  # re-reads the winner's row.
  def ensure!
    account = operator_account!

    find_row(account) || create_row!(account)
  rescue ActiveRecord::RecordNotUnique
    find_row(operator_account!) || raise
  end

  def pems
    ensure!.value
  end

  # Memoized per process and keyed on the leaf PEM, so a rotated certificate
  # (or a spec seeding a different row) is never served from a stale memo.
  def pkcs
    cert_data = pems

    if @pkcs_cert_pem != cert_data['cert']
      @pkcs = GenerateCertificate.load_pkcs(cert_data)
      @pkcs_cert_pem = cert_data['cert']
    end

    @pkcs
  end

  def trusted_certs
    cert_data = pems

    %w[cert sub_ca root_ca].filter_map do |key|
      OpenSSL::X509::Certificate.new(cert_data[key]) if cert_data[key].present?
    end
  end

  # SHA-256 of the leaf certificate DER, colon-separated hex: the value Evan
  # keeps with the offline custody copy.
  def fingerprint
    OpenSSL::Digest::SHA256.new(OpenSSL::X509::Certificate.new(pems['cert']).to_der)
                           .hexdigest.upcase.scan(/../).join(':')
  end

  def operator_account!
    OperatorConfigs.account ||
      raise(MissingOperatorAccountError, 'No operator account exists; run `rake operator:seed`')
  end

  def find_row(account)
    account.encrypted_configs.find_by(key: KEY)
  end

  def create_row!(account)
    account.encrypted_configs.create!(
      key: KEY,
      value: GenerateCertificate.call(Docuseal.product_name).transform_values(&:to_pem).stringify_keys
    )
  end
end
