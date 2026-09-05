# frozen_string_literal: true

module Api
  class ApiBaseController < ActionController::API
    include ActiveStorage::SetCurrent
    include Pagy::Method
    include TokenAccountGuard
    include AccountActivityStamp
    # `/api/*` accepts the BROWSER SESSION as well as a token (the in-app
    # builder and dashboard call it with the cookie), so a support session can
    # reach every door below. The same rule that governs the HTML doors
    # therefore governs these, keyed on the same classification: read is read,
    # document work needs edit mode, and `api/submitters#update` — which takes
    # `completed: true` and signs for the person — is refused outright. A
    # request that authenticated with a TOKEN is a different client and is
    # untouched (see `support_impersonation` below).
    include SupportImpersonationGuard

    DEFAULT_LIMIT = 10
    MAX_LIMIT = 100

    impersonates :user, with: ->(uuid) { User.find_by(uuid:) }

    wrap_parameters false

    # Both token guards run on EVERY request that presents a token —
    # including the controllers below that skip authenticate_user! (blob
    # proxies, tracking endpoints) yet still authorize through current_user.
    # State first, then entitlement. Subclasses never skip either.
    before_action :refuse_inactive_token_account!
    before_action :refuse_unentitled_token_account!
    before_action :authenticate_user!
    before_action :enforce_support_impersonation!
    check_authorization

    rescue_from Params::BaseValidator::InvalidParameterError do |e|
      render json: { error: e.message }, status: :unprocessable_content
    end

    rescue_from Entitlements::UpgradeRequired do |e|
      render json: { error: Entitlements.refusal_message(e.feature) }, status: :forbidden
    end

    # A quota or sending-pause refusal on any creation door (submissions,
    # signing sessions): nothing was created, the message says why.
    rescue_from Quotas::LimitReached do |e|
      render json: { error: e.message }, status: :unprocessable_content
    end

    # The storage cap on every API door that stores a document (templates,
    # signing sessions, builder sessions): nothing is created.
    rescue_from Quotas::StorageLimitReached do |e|
      render json: { error: e.message }, status: :unprocessable_content
    end

    rescue_from RateLimit::LimitApproached do |e|
      ErrorReport.error(e)

      render json: { error: 'Too many requests' }, status: :too_many_requests
    end

    unless Rails.env.development?
      rescue_from CanCan::AccessDenied do |e|
        record_support_impersonation_refusal!(support_impersonation, 'refused_by' => 'ability')

        render json: { error: access_denied_error_message(e) }, status: :forbidden
      end

      rescue_from JSON::ParserError do |e|
        ErrorReport.warning(e)

        render json: { error: "JSON parse error: #{e.message}" }, status: :unprocessable_content
      end
    end

    private

    def access_denied_error_message(error)
      return 'Not authorized' if request.headers['X-Auth-Token'].blank?
      return 'Not authorized' unless error.subject.is_a?(ActiveRecord::Base)
      return 'Not authorized' unless error.subject.respond_to?(:account_id)

      linked_account_record_exists =
        if current_user.account.testing?
          current_user.account.linked_account_accounts.where(account_type: 'testing')
                      .exists?(account_id: error.subject.account_id)
        else
          current_user.account.testing_accounts.exists?(id: error.subject.account_id)
        end

      return 'Not authorized' unless linked_account_record_exists

      object_name = error.subject.model_name.human
      id = error.subject.id

      if current_user.account.testing?
        "#{object_name} #{id} not found using testing API key; Use production API key to " \
          "access production #{object_name.downcase.pluralize}."
      else
        "#{object_name} #{id} not found using production API key; Use testing API key to " \
          "access testing #{object_name.downcase.pluralize}."
      end
    end

    def paginate(relation, field: :id)
      result = relation.order(field => :desc)
                       .limit([params.fetch(:limit, DEFAULT_LIMIT).to_i, MAX_LIMIT].min)

      if field == :id
        result = result.where(id: ...params[:after].to_i) if params[:after].present?
        result = result.where(id: (params[:before].to_i + 1)...) if params[:before].present?
      else
        result = result.where(field => ...params[:after]) if params[:after].present?
        result = result.where(field => (params[:before] + 1)...) if params[:before].present?
      end

      result
    end

    # The API half of the dormancy stamp (AccountActivityStamp).
    #
    # An account driven entirely through the REST API is an account in daily
    # use, and it moves a Devise sign-in timestamp exactly never — so without
    # this it would look untouched for a year and be purged. Stamped from
    # `authenticate_user!` for the same reason as in ApplicationController:
    # the controllers here that legitimately serve the SIGNER (the blob
    # proxy, the open/click trackers) skip this callback, so their traffic
    # can never be mistaken for the account's own.
    def authenticate_user!
      return render json: { error: 'Not authenticated' }, status: :unauthorized unless current_user

      record_account_activity!
    end

    # The REST API is a paid-only surface for the TOKEN: a request that
    # authenticated with X-Auth-Token from an account without the :api
    # entitlement is refused here, existing tokens included. The same
    # endpoints keep working over the browser session (the in-app builder and
    # dashboard call /api/* with the session cookie), so nothing is checked
    # when user_from_token is nil — anonymous and session requests pass
    # through untouched. It is its own before_action rather than part of
    # authenticate_user! so the controllers that skip authentication yet
    # still authorize through the token (the blob proxy) refuse a free token
    # too: an expired download link is the one place a free token would
    # otherwise do real work.
    def refuse_unentitled_token_account!
      return if user_from_token.nil?
      return if Entitlements.allowed?(current_account, :api)

      render json: { error: Entitlements::REFUSAL_MESSAGE }, status: :forbidden
    end

    # Session users are governed by Devise (an archived account cannot sign
    # in); a token keeps working until its account state says otherwise.
    # Anonymous requests and unknown tokens resolve to nobody and pass through
    # untouched — authenticate_user! (where not skipped) handles them.
    def token_account_user
      user_from_token
    end

    def current_user
      super || @current_user ||= user_from_token
    end

    # The support rule is about the BROWSER. A request with no signed-in Devise
    # user is a token client — it carries no session for a support session to
    # ride in on — and is left alone, which is what keeps genuine API and MCP
    # traffic out of the impersonation machinery entirely. A request that IS
    # session-authenticated meets the rule even when a token header rode along
    # with it, so adding a header can never switch the rule off.
    def support_impersonation
      return nil if true_user.blank?

      super
    end

    # Every refusal on this surface is JSON; there is no page to render.
    def json_request?
      true
    end

    # The same ability the HTML doors get, for the same reason.
    def current_ability
      @current_ability ||= Ability.new(current_user, support_impersonation: support_impersonation_mode)
    end

    def user_from_token
      return @user_from_token if defined?(@user_from_token)
      return @user_from_token = nil if request.headers['X-Auth-Token'].blank?

      sha256 = Digest::SHA256.hexdigest(request.headers['X-Auth-Token'])

      @user_from_token = User.joins(:access_token).active.find_by(access_token: { sha256: })
    end

    def current_account
      current_user&.account
    end

    def set_noindex_headers
      headers['X-Robots-Tag'] = 'noindex'
    end

    def set_security_headers
      response.headers['X-Content-Type-Options'] = 'nosniff'
    end

    def set_cors_headers
      headers['Access-Control-Allow-Origin'] = '*'
      headers['Access-Control-Allow-Methods'] = 'POST, GET, PUT, PATCH, DELETE, OPTIONS'
      headers['Access-Control-Allow-Headers'] = '*'
      headers['Access-Control-Max-Age'] = '1728000'
      headers['Access-Control-Allow-Credentials'] = true
    end
  end
end
