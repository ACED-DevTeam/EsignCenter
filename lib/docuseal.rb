# frozen_string_literal: true

module Docuseal
  # Upstream source repository — the target of the AGPL-required DocuSeal
  # attribution (see LICENSE_ADDITIONAL_TERMS). The attribution owes the reader
  # the upstream project's source, never its commercial site or signup funnel,
  # so this is the repo URL; the upstream domain appears nowhere in app code
  # and `rake gates:branding` refuses it (BANNED_LITERALS, no allowlist entry).
  DOCUSEAL_SOURCE_URL = 'https://github.com/docusealco/docuseal'
  PRODUCT_URL = 'https://github.com/ACED-DevTeam/EsignCenter'
  PRODUCT_NAME = 'EsignCenter'
  DEFAULT_APP_URL = ENV.fetch('APP_URL', 'http://localhost:3000')
  # Where the "Sent using EsignCenter" line in a signer's mail points. That
  # line is free-plan product branding (D45), not the AGPL attribution, and a
  # signer who follows it wants the product, not our source tree — so it is the
  # app's own address, overridable per deployment.
  PRODUCT_EMAIL_URL = ENV.fetch('PRODUCT_EMAIL_URL', DEFAULT_APP_URL)
  GITHUB_URL = 'https://github.com/ACED-DevTeam/EsignCenter'
  SUPPORT_EMAIL = 'evan@processorteam.com'

  # There is no environment escape hatch for signing certificates: every
  # account signs with the platform certificate or its own row (Session 4).
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

  # Never flipped in EsignCenter (decision-locked); kept only as the guard the
  # remaining infra-keep branches read. See docs/feature-gating.md section 2.
  def multitenant?
    ENV['MULTITENANT'] == 'true'
  end

  def registration_enabled?
    ENV['REGISTRATION_ENABLED'] == 'true'
  end

  def billing_enabled?
    ENV['BILLING_ENABLED'] == 'true'
  end

  # Word (.docx/.doc) uploads are offered whenever the converter can run:
  # LibreOffice on PATH and the WORD_CONVERSION_ENABLED kill switch not set to
  # 'false'. See docs/word-uploads.md.
  def advanced_formats?
    WordConverter.enabled?
  end

  def demo?
    ENV['DEMO'] == 'true'
  end

  def active_storage_public?
    ENV['ACTIVE_STORAGE_PUBLIC'] == 'true'
  end

  # Local environments may deliberately build HTTP links. Production's boot
  # guard requires the literal value "true", so production links and Rails'
  # unconditional HTTPS handling cannot disagree.
  def force_ssl?
    ENV['FORCE_SSL'].present? && ENV['FORCE_SSL'] != 'false'
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
