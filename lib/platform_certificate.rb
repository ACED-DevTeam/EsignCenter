# frozen_string_literal: true

# The ONE signing identity every customer account signs with. It lives as an
# encrypted row on the platform-operator account (never on a tenant account)
# and is exported for offline custody with `rake operator:platform_cert:export`.
#
# Two kinds of readers, deliberately separate:
# - `ensure!` / `pkcs` GENERATE the row when it is missing. Only signing and
#   `rake operator:seed` may call them.
# - `current_chain`, `retired_chains`, `fingerprint` and friends never
#   generate anything: they answer from what exists (an empty chain when the
#   row or the operator account is missing). Every verification path — the
#   public /verify page, the API verify tool, trust-set builders — reads
#   through these, so an anonymous upload can never mint the platform key.
#
# Rotation (`rotate!`, rake operator:platform_cert:rotate) never deletes a
# chain: the current one is appended to an append-only retired list on the
# operator account so documents signed under it keep verifying forever.
#
# Internal accounts keep their own certificate rows (Accounts.load_signing_pkcs);
# this module is only about the platform identity.
module PlatformCertificate
  KEY = EncryptedConfig::PLATFORM_ESIGN_CERTS_KEY
  RETIRED_KEY = EncryptedConfig::PLATFORM_ESIGN_CERTS_RETIRED_KEY

  CHAIN_KEYS = %w[cert sub_ca root_ca].freeze

  # The offline custody bundle: the signing identity first, then its CA chain,
  # then every private key.
  EXPORT_ORDER = %w[cert sub_ca root_ca key sub_key root_key].freeze

  # A missing operator account is a deployment error, not a signing edge case:
  # signing stops loudly instead of falling back to some other account's cert.
  class MissingOperatorAccountError < OperatorConfigs::MissingOperatorAccountError; end

  # A read that needs the row (fingerprint, export, rotate) when none exists.
  class MissingCertificateError < StandardError; end

  module_function

  # The platform certificate row, generating it on first use. Idempotent under
  # a race: the unique index on (account_id, key) decides, and the loser
  # re-reads the winner's row. Signing and `rake operator:seed` only.
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

  # --- Non-generating readers -------------------------------------------

  # The current row, or nil when there is none (or no operator account).
  def current_row
    operator_row(KEY)
  end

  # Never generates: a missing operator account or a missing row answers nil.
  def operator_row(key)
    account = OperatorConfigs.account

    account && find_row(account, key:)
  end

  # The current row's PEMs; raises when there is nothing to read.
  def current_pems!
    current_row&.value ||
      raise(MissingCertificateError, 'No platform certificate exists; run `rake operator:seed`')
  end

  # [leaf, sub_ca, root_ca] of the current row, or [] when there is none.
  def current_chain
    chain_certs(current_row&.value)
  end

  # Every chain retired by a rotation, oldest first, as certificates.
  def retired_chains
    retired_entries.flat_map { |entry| chain_certs(entry) }
  end

  def retired_entries
    Array(operator_row(RETIRED_KEY)&.value)
  end

  # SHA-256 of the leaf certificate DER, colon-separated hex: the value Evan
  # keeps with the offline custody copy.
  def fingerprint(cert_pem = current_pems!['cert'])
    fingerprint_of(OpenSSL::X509::Certificate.new(cert_pem))
  end

  def fingerprint_of(certificate)
    OpenSSL::Digest::SHA256.new(certificate.to_der).hexdigest.upcase.scan(/../).join(':')
  end

  # Retires the current chain (appended to the retired list, never deleted)
  # and replaces the row with a freshly generated identity. Returns the old
  # and the new fingerprint. Requires an existing row: rotation is a change
  # of identity, not a first seed.
  #
  # The current row is read and row-locked INSIDE the transaction, and the
  # retired chain is taken from that locked read: two rotations running at
  # once serialize on the lock, so the second retires the first one's fresh
  # identity instead of retiring the same old chain twice and orphaning a
  # leaf that may already have signed a document.
  def rotate!
    account = operator_account!
    new_pems = generate_pems
    old_pems = nil

    ApplicationRecord.transaction do
      row = account.encrypted_configs.lock.find_by(key: KEY) ||
            raise(MissingCertificateError, 'No platform certificate to rotate; run `rake operator:seed` first')

      old_pems = row.value

      retired = account.encrypted_configs.lock.find_or_initialize_by(key: RETIRED_KEY)
      retired.value = Array(retired.value) + [old_pems.slice(*CHAIN_KEYS).merge('retired_at' => Time.current.iso8601)]
      retired.save!

      row.update!(value: new_pems)
    end

    reset_memo!

    [fingerprint(old_pems['cert']), fingerprint(new_pems['cert'])]
  end

  def reset_memo!
    @pkcs = nil
    @pkcs_cert_pem = nil
  end

  def operator_account!
    OperatorConfigs.account ||
      raise(MissingOperatorAccountError, 'No operator account exists; run `rake operator:seed`')
  end

  def find_row(account, key: KEY)
    account.encrypted_configs.find_by(key:)
  end

  def create_row!(account)
    account.encrypted_configs.create!(key: KEY, value: generate_pems)
  end

  def generate_pems
    GenerateCertificate.call(Docuseal.product_name).transform_values(&:to_pem).stringify_keys
  end

  def chain_certs(cert_data)
    return [] if cert_data.blank?

    CHAIN_KEYS.filter_map do |key|
      OpenSSL::X509::Certificate.new(cert_data[key]) if cert_data[key].present?
    end
  end
end
