# frozen_string_literal: true

# Read-only pre-deploy audit of what this release changes for the internal
# (and operator) accounts — the integrating apps that were already running on
# the old code. Run it against the restored copy of production during the
# migration rehearsal (docs/operations.md section 2.3), after the migrations:
#
#   * formula fields are refused for every account now (D30/D47): cloning a
#     template that carries one, or creating one through the API, fails. Each
#     template that carries a formula is listed so the owning app can be
#     checked before the deploy;
#   * webhook URLs of internal accounts get the production outbound rules —
#     HTTPS on port 443, no localhost, no private or link-local address,
#     checked with the real validator (SendWebhookRequest). Each URL those
#     rules would refuse is listed with its account and HOST only: never the
#     path, query, credentials, secret or headers.
#
# Nothing is written: the whole audit runs under while_preventing_writes.
module ReleaseInternalAudit
  FormulaTemplate = Data.define(:account_id, :template_id, :name, :formula_fields, :archived)
  RefusedWebhook = Data.define(:account_id, :webhook_url_id, :host, :reason)
  Result = Data.define(:formula_templates, :refused_webhooks) do
    def findings?
      formula_templates.any? || refused_webhooks.any?
    end
  end

  module_function

  def call
    ActiveRecord::Base.while_preventing_writes do
      Result.new(formula_templates:, refused_webhooks:)
    end
  end

  def audited_accounts
    Account.where.not(account_kind: Account::CUSTOMER_KIND)
  end

  def formula_templates
    Template.where(account_id: audited_accounts.select(:id)).find_each.filter_map do |template|
      count = Array(template.fields).count { |field| formula?(field) }

      next if count.zero?

      FormulaTemplate.new(account_id: template.account_id, template_id: template.id, name: template.name,
                          formula_fields: count, archived: template.archived_at.present?)
    end
  end

  def formula?(field)
    Templates::AssertEntitledFields.content_of(Templates::AssertEntitledFields.normalize(field), :formula).present?
  end

  def refused_webhooks
    WebhookUrl.where(account_id: audited_accounts.select(:id)).includes(:account)
              .find_each.filter_map do |webhook_url|
      reason = refusal(webhook_url)

      next if reason.nil?

      RefusedWebhook.new(account_id: webhook_url.account_id, webhook_url_id: webhook_url.id,
                         host: host_of(webhook_url.url), reason:)
    end
  end

  # What delivery would do under the production rules, in the validator's
  # own words, or nil when the URL would be delivered to.
  def refusal(webhook_url)
    uri = SendWebhookRequest.validate_url!(webhook_url.url, webhook_url.account, strict: true)
    SendWebhookRequest.deliverable_address!(uri, webhook_url.account, strict: true)

    nil
  rescue SendWebhookRequest::HttpsError
    'not HTTPS on port 443'
  rescue SendWebhookRequest::PrivateAddressError
    'private or internal network address'
  rescue SendWebhookRequest::LocalhostError
    'localhost'
  rescue SendWebhookRequest::MetadataHostError
    'link-local or cloud metadata address'
  rescue SendWebhookRequest::InvalidUrlError
    'not a valid http(s) URL'
  rescue Faraday::ConnectionFailed
    'host does not resolve from here (re-check from the production shell)'
  end

  def host_of(url)
    SendWebhookRequest.parse_uri(url).host.presence || '(no host)'
  rescue SendWebhookRequest::InvalidUrlError
    '(unparseable)'
  end

  def report(result)
    lines = ['EsignCenter internal-account audit (read-only; no URLs, secrets or headers are printed)', '',
             "Templates with formula fields (#{result.formula_templates.size}) — cloning or re-creating " \
             'them is refused from this release on:']
    result.formula_templates.each do |t|
      lines << "  account #{t.account_id} template #{t.template_id} #{t.name.inspect}: " \
               "#{t.formula_fields} formula field(s)#{' (archived)' if t.archived}"
    end
    lines << '  none' if result.formula_templates.empty?
    lines += ['', "Webhook URLs the production outbound rules refuse (#{result.refused_webhooks.size}):"]
    result.refused_webhooks.each do |w|
      lines << "  account #{w.account_id} webhook #{w.webhook_url_id} host #{w.host}: #{w.reason}"
    end
    lines << '  none' if result.refused_webhooks.empty?

    lines.join("\n")
  end
end
