# frozen_string_literal: true

module Docuseal
  # Upstream project URL — used for the AGPL-required DocuSeal attribution
  # (see LICENSE_ADDITIONAL_TERMS).
  DOCUSEAL_URL = 'https://www.docuseal.com'
  PRODUCT_URL = 'https://github.com/AmishHillBilly/EsignCenter'
  PRODUCT_EMAIL_URL = ENV.fetch('PRODUCT_EMAIL_URL', PRODUCT_URL)
  PRODUCT_NAME = 'EsignCenter'
  DEFAULT_APP_URL = ENV.fetch('APP_URL', 'http://localhost:3000')
  GITHUB_URL = 'https://github.com/AmishHillBilly/EsignCenter'
  SUPPORT_EMAIL = 'evan@processorteam.com'
  AATL_CERT_NAME = 'docuseal_aatl'

  CERTS = JSON.parse(ENV.fetch('CERTS', '{}'))
  TIMESERVER_URL = ENV.fetch('TIMESERVER_URL', nil)
  VERSION_FILE_PATH = Rails.root.join('.version')
  VERSION_FILE2_PATH = Rails.public_path.join('version')

  module_function

  def version
    @version ||=
      if VERSION_FILE_PATH.exist?
        VERSION_FILE_PATH.read.strip
      elsif VERSION_FILE2_PATH.exist?
        VERSION_FILE2_PATH.each_line.first.to_s.strip
      end
  end

  def multitenant?
    ENV['MULTITENANT'] == 'true'
  end

  def registration_enabled?
    ENV['REGISTRATION_ENABLED'] == 'true'
  end

  def billing_enabled?
    ENV['BILLING_ENABLED'] == 'true'
  end

  def advanced_formats?
    multitenant?
  end

  def demo?
    ENV['DEMO'] == 'true'
  end

  def active_storage_public?
    ENV['ACTIVE_STORAGE_PUBLIC'] == 'true'
  end

  # The same predicate config/environments/production.rb uses for force_ssl /
  # assume_ssl, so generated links agree with how the app is actually served:
  # FORCE_SSL='false' means http.
  def force_ssl?
    ENV['FORCE_SSL'].present? && ENV['FORCE_SSL'] != 'false'
  end

  def default_pkcs
    return if Docuseal::CERTS['enabled'] == false

    @default_pkcs ||= GenerateCertificate.load_pkcs(Docuseal::CERTS)
  end

  # Instance-global toggle, memoized per process; the operator surface that
  # flips it calls refresh_fulltext_search! afterwards.
  def fulltext_search?
    return @fulltext_search unless @fulltext_search.nil?

    @fulltext_search =
      SearchEntry.table_exists? && (Docuseal.multitenant? || OperatorConfigs.enabled?(:fulltext_search))
  end

  def refresh_fulltext_search!
    @fulltext_search = nil
  end

  def enable_pwa?
    true
  end

  def pdf_format
    @pdf_format ||= ENV['PDF_FORMAT'].to_s.downcase
  end

  def trusted_certs
    @trusted_certs ||=
      ENV['TRUSTED_CERTS'].to_s.gsub('\\n', "\n").split("\n\n").map do |base64|
        OpenSSL::X509::Certificate.new(base64)
      end
  end

  # The environment is the only source of the application URL: APP_URL wins,
  # then HOST (+ FORCE_SSL for https; a HOST that carries its own port such as
  # `localhost:3015` is used as-is), then the local default.
  def default_url_options
    @default_url_options ||=
      if ENV['APP_URL'].present?
        url = Addressable::URI.parse(ENV['APP_URL'])
        { host: url.host, port: url.port, protocol: url.scheme }
      elsif ENV['HOST'].present?
        { host: ENV.fetch('HOST'), protocol: force_ssl? ? 'https' : 'http' }
      else
        { host: 'localhost', port: 3000, protocol: 'http' }
      end
  end

  def product_name
    PRODUCT_NAME
  end

  def refresh_default_url_options!
    @default_url_options = nil
  end
end
