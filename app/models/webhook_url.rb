# frozen_string_literal: true

# == Schema Information
#
# Table name: webhook_urls
#
#  id          :bigint           not null, primary key
#  events      :text             not null
#  hmac_secret :text             not null
#  secret      :text             not null
#  sha1        :string           not null
#  url         :text             not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  account_id  :bigint           not null
#
# Indexes
#
#  index_webhook_urls_on_account_id  (account_id)
#  index_webhook_urls_on_sha1        (sha1)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class WebhookUrl < ApplicationRecord
  EVENTS = %w[
    form.viewed
    form.started
    form.completed
    form.declined
    submission.created
    submission.completed
    submission.expired
    submission.archived
    template.created
    template.updated
    template.archived
  ].freeze

  belongs_to :account
  has_many :webhook_events, dependent: nil

  attribute :events, :string, default: -> { %w[form.viewed form.started form.completed form.declined] }
  attribute :secret, :string, default: -> { {} }

  serialize :events, coder: JSON
  serialize :secret, coder: JSON

  before_validation :set_sha1
  before_validation :set_hmac_secret

  # Validated wherever delivery enforces the strict rules (every customer
  # account; every account in production — SendWebhookRequest.strict_rules?),
  # so a URL delivery would refuse is refused when it is saved instead of
  # failing silently later. Only a NEW or CHANGED URL is validated: a legacy
  # row with an http URL keeps saving its events, secret and headers (a downgrade never
  # blocks cleanup, D43); delivery refuses the unsafe URL with a terminal
  # error instead (SendWebhookRequest).
  validate :url_deliverable, if: lambda {
    account && SendWebhookRequest.strict_rules?(account) && (new_record? || will_save_change_to_url?)
  }

  encrypts :url, :secret, :hmac_secret

  # Validation messages read "Webhook URL must use https" (the flash joins
  # the attribute name and the message).
  def self.human_attribute_name(attribute, options = {})
    attribute.to_s == 'url' ? I18n.t('webhook_url') : super
  end

  def set_sha1
    self.sha1 = Digest::SHA1.hexdigest(url)
  end

  def set_hmac_secret
    self.hmac_secret ||= WebhookUrls::Signatures.generate_secret
  end

  private

  def url_deliverable
    SendWebhookRequest.validate_url!(url, account)
  rescue SendWebhookRequest::InvalidUrlError
    errors.add(:url, :invalid, message: I18n.t('webhook_url_must_be_a_full_url'))
  rescue SendWebhookRequest::HttpsError
    errors.add(:url, :invalid, message: I18n.t('webhook_url_must_use_https'))
  rescue SendWebhookRequest::LocalhostError, SendWebhookRequest::MetadataHostError
    errors.add(:url, :invalid, message: I18n.t('webhook_url_must_not_point_at_a_private_address'))
  end
end
