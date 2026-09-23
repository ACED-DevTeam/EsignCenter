# frozen_string_literal: true

module TemplatePreviewSessions
  class Create
    Session = Data.define(:template, :token, :origin, :values, :expires_at)

    VALUE_KEYS_LIMIT = Params::TemplatePreviewSessionCreateValidator::MAX_VALUES

    def self.call(...)
      new(...).call
    end

    def initialize(user:, attrs:, ability: nil)
      @user = user
      @attrs = attrs.to_h.with_indifferent_access
      @ability = ability || Ability.new(user)
    end

    def call
      template = Template.accessible_by(ability, :read).find(attrs[:template_id])

      # `accessible_by(:read)` also grants templates SHARED into this account
      # (linked/testing accounts). A preview token is a public, login-free URL
      # for the template's full contents, so it is minted only for templates
      # this account actually owns.
      raise ActiveRecord::RecordNotFound if template.account_id != user.account_id
      # An archived template is gone as far as the sender is concerned.
      raise ActiveRecord::RecordNotFound if template.archived_at?

      origin = EmbedOrigins.normalize(attrs[:embed_origin])
      values = normalized_values
      expires_at = self.expires_at

      token = TemplatePreviewSessions.generate_token(
        template_id: template.id,
        account_id: template.account_id,
        origin:,
        values:,
        expires_in: [expires_at - Time.current, 1.second].max
      )

      Session.new(template:, token:, origin:, values:, expires_at:)
    end

    private

    attr_reader :user, :attrs, :ability

    def normalized_values
      values = attrs[:values]

      return {} if values.blank?

      values.to_h.first(VALUE_KEYS_LIMIT).to_h { |key, value| [key.to_s, value.to_s] }.compact_blank
    end

    def expires_at
      minutes = attrs[:expires_in_minutes].presence&.to_i
      duration = minutes ? minutes.minutes : DEFAULT_EXPIRES_IN

      Time.current + [duration, MAX_EXPIRES_IN].min
    end
  end
end
