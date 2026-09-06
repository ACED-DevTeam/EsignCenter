# frozen_string_literal: true

module Api
  module Admin
    # Provisioning endpoint for trusted upstream applications (e.g. a CRM that
    # manages firm workspaces). Creates an isolated account with an admin user,
    # API access token, per-account e-sign certificates and an optional webhook
    # subscription in a single call.
    #
    # Guarded by ADMIN_PROVISION_TOKEN: requests must send the exact token in
    # the X-Admin-Token header. The endpoint is disabled unless the env var is
    # configured.
    class AccountsController < ApiBaseController
      skip_before_action :authenticate_user!
      skip_authorization_check

      before_action :authenticate_admin_token!

      DEFAULT_WEBHOOK_EVENTS = %w[form.completed form.declined submission.completed submission.expired].freeze

      def create
        result = provision_account

        if result[:replayed]
          render_replay(result[:event])
        else
          Rails.logger.info("provisioned account #{result[:event].account_id} for #{result[:event].email}")

          render_provisioning_event(result[:event], status: :created)
        end
      rescue ActiveRecord::RecordNotUnique
        handle_not_unique
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_content
      end

      private

      # A replayed idempotency key must carry the same request; otherwise the
      # caller would silently receive some other account's credentials.
      def render_replay(event)
        if event.email == requested_email
          Rails.logger.info(
            "provisioning replay for account #{event.account_id} (idempotency key #{event.idempotency_key})"
          )

          render_provisioning_event(event, status: :ok)
        else
          Rails.logger.warn(
            "provisioning idempotency conflict for account #{event.account_id} " \
            "(idempotency key #{event.idempotency_key} reused with different parameters)"
          )

          render json: { error: 'Idempotency key was already used with different parameters' }, status: :conflict
        end
      end

      def handle_not_unique
        event = existing_provisioning_event

        if event
          render_replay(event)
        elsif User.exists?(email: requested_email)
          # Lost a race on the unique users.email index, not on the
          # idempotency key — same contract as the validation-time duplicate.
          render_duplicate_email
        else
          raise
        end
      end

      # The wire contract for a plain duplicate email is the Rails validation
      # response (422 + "Email has already been taken"), whether the duplicate
      # is caught by the uniqueness validation or by the unique index. 409 is
      # reserved for an idempotency key replayed with different parameters.
      def render_duplicate_email
        errors = ActiveModel::Errors.new(User.new)
        errors.add(:email, :taken)

        render json: { error: errors.full_messages.join(', ') }, status: :unprocessable_content
      end

      def requested_email
        account_params[:email].to_s.strip.downcase
      end

      def provision_account
        ApplicationRecord.transaction do
          if (event = existing_provisioning_event)
            next { event:, replayed: true }
          end

          account = create_account
          user = create_admin_user(account)

          account.encrypted_configs.create!(
            key: EncryptedConfig::ESIGN_CERTS_KEY,
            value: GenerateCertificate.call.transform_values(&:to_pem)
          )

          # Audit stamping ON by default for provisioned firm accounts: every
          # signed document gets the per-signature ID/reason stamp and the
          # "Document ID" page footer. Upstream firms never sign in to the
          # signing app to toggle this themselves, so it must be set here.
          account.account_configs.create!(
            key: AccountConfig::WITH_SIGNATURE_ID,
            value: true
          )

          webhook_url = create_webhook_url(account)
          event = ProvisioningEvent.create!(
            account:,
            idempotency_key: idempotency_key,
            email: user.email,
            webhook_url_id: webhook_url&.id
          )

          { event:, replayed: false }
        end
      end

      def render_provisioning_event(event, status:)
        account = event.account
        user = account.users.order(:id).first!
        webhook_url = WebhookUrl.find_by(id: event.webhook_url_id, account:)

        render json: {
          account_id: account.id,
          account_uuid: account.uuid,
          user_id: user.id,
          email: event.email,
          api_token: user.access_token.token,
          webhook_url_id: webhook_url&.id,
          # The per-webhook HMAC key every delivery is signed with
          # (X-Docuseal-Signature). Returned ONCE at provisioning so the
          # receiver can actually verify the signatures — without it the
          # signature header is unverifiable noise to the receiving app.
          webhook_hmac_secret: webhook_url&.hmac_secret
        }, status:
      end

      def create_account
        Account.create!(
          name: account_params[:name].presence || 'New Account',
          timezone: Accounts.normalize_timezone(account_params[:timezone].presence || 'UTC'),
          locale: account_params[:locale].presence || 'en-US',
          account_kind: Account::INTERNAL_KIND
        )
      end

      def create_admin_user(account)
        user = account.users.new(
          email: account_params[:email].to_s.strip.downcase,
          password: SecureRandom.base58(24),
          first_name: account_params[:first_name].presence || 'Admin',
          last_name: account_params[:last_name].presence || 'User',
          role: User::ADMIN_ROLE
        )
        user.skip_confirmation!
        user.save!
        user.access_token
        user
      end

      def existing_provisioning_event
        ProvisioningEvent.find_by(idempotency_key:) if idempotency_key.present?
      end

      def idempotency_key
        account_params[:idempotency_key].presence
      end

      def authenticate_admin_token!
        configured_token = ENV.fetch('ADMIN_PROVISION_TOKEN', nil)

        # The dev compose file ships a publicly-known dev_prov_ token; production
        # must generate its own, so a dev value counts as not configured.
        configured_token = nil if Rails.env.production? && configured_token.to_s.start_with?('dev_prov_')

        if configured_token.blank?
          return render json: { error: 'Account provisioning is not enabled' }, status: :forbidden
        end

        provided_token = request.headers['X-Admin-Token'].to_s

        return if provided_token.present? &&
                  ActiveSupport::SecurityUtils.secure_compare(provided_token, configured_token)

        render json: { error: 'Not authenticated' }, status: :unauthorized
      end

      def create_webhook_url(account)
        return if webhook_params[:url].blank?

        events = Array(webhook_params[:events]) & WebhookUrl::EVENTS

        account.webhook_urls.create!(
          url: webhook_params[:url],
          events: events.presence || DEFAULT_WEBHOOK_EVENTS,
          # Optional delivery headers (e.g. Authorization: Bearer <secret>) so
          # the receiver can authenticate events without a secret in the URL.
          secret: webhook_params[:secret].presence.to_h
        )
      end

      def account_params
        params.permit(:name, :email, :first_name, :last_name, :timezone, :locale, :idempotency_key)
      end

      # The webhook to subscribe, in either shape a caller sends it.
      #
      # `webhook[url]` is the nested shape the documentation has always shown.
      # A FLAT `webhook_url` (with `webhook_events` and `webhook_secret`) is
      # what people reach for when they build the body by hand, and it used to
      # be read by nothing at all: the account was created, `201` came back
      # with `webhook_url_id: null`, and no subscription existed — a silent
      # miss that only turns up when the first event never arrives (session 10
      # staging walk, W4). Both shapes are accepted now; the nested one wins if
      # a caller somehow sends both, and neither is required.
      def webhook_params
        @webhook_params ||= nested_webhook_params.presence || flat_webhook_params
      end

      def nested_webhook_params
        return {} if params[:webhook].blank?

        params.require(:webhook).permit(:url, events: [], secret: {})
      end

      def flat_webhook_params
        return {} if params[:webhook_url].blank?

        { url: params[:webhook_url].to_s,
          events: flat_webhook_events,
          secret: params.permit(webhook_secret: {})[:webhook_secret] }
      end

      # A list in JSON; one comma-separated string when the request is a form
      # post or the parameters ride on the query string.
      def flat_webhook_events
        raw = params[:webhook_events]
        raw = raw.to_s.split(',') if raw.is_a?(String)

        Array(raw).map { |event| event.to_s.strip }
      end
    end
  end
end
