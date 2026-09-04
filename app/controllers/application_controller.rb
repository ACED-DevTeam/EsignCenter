# frozen_string_literal: true

class ApplicationController < ActionController::Base
  BROWSER_LOCALE_REGEXP = /\A\w{2}(?:-\w{2})?/

  include ActiveStorage::SetCurrent
  include Pagy::Method
  include OperatorAccess
  include AccountActivityStamp

  check_authorization unless: :devise_controller?

  around_action :with_locale
  before_action :sign_in_for_demo, if: -> { Docuseal.demo? }
  before_action :maybe_redirect_to_setup, unless: :signed_in?
  before_action :authenticate_user!, unless: :devise_controller?

  before_action :set_csp, if: -> { request.get? && !request.headers['HTTP_X_TURBO'] }

  helper_method :button_title,
                :current_account,
                :true_ability,
                :form_link_host,
                :svg_icon,
                :account_logo_url,
                :test_mode_available?,
                :billing_available?,
                :upgrade_cta_path

  impersonates :user, with: ->(uuid) { User.find_by(uuid:) }

  rescue_from Pagy::RangeError do
    redirect_to request.path
  end

  # A paid-only feature reached from an account whose plan lacks it. JSON
  # callers (the builder saves with a JSON body; fetch/XHR) get the API shape;
  # a browser form goes back where it came from with an alert. The decision is
  # always about the acting user's account, never the request's own claims.
  rescue_from Entitlements::UpgradeRequired do |e|
    if request.format.json? || request.xhr? || request.content_mime_type&.json?
      render json: { error: Entitlements.refusal_message(e.feature) }, status: :forbidden
    else
      redirect_back fallback_location: root_path, alert: Entitlements.refusal_alert(e.feature)
    end
  end

  rescue_from RateLimit::LimitApproached do |e|
    ErrorReport.error(e)

    redirect_to request.referer, alert: 'Too many requests', status: :too_many_requests
  end

  if Rails.env.production? || Rails.env.test?
    rescue_from CanCan::AccessDenied do |e|
      ErrorReport.warning(e)

      redirect_to root_path, alert: e.message
    end
  end

  def default_url_options
    Docuseal.default_url_options
  end

  # Ordinary authenticated use is what keeps an account out of the dormant
  # purge (AccountActivityStamp, which explains why the stamp rides on this
  # callback rather than on one of its own). `super` throws `:warden` when
  # the request is NOT authenticated, so nothing below it can run for an
  # anonymous visitor.
  def authenticate_user!(...)
    super

    record_account_activity!
  end

  def impersonate_user(user)
    raise ArgumentError unless user
    raise Pretender::Error unless true_user

    @impersonated_user = user

    request.session[:impersonated_user_id] = user.uuid
  end

  def pagy_auto(collection, **keyword_args)
    if current_ability.can?(:manage, :countless)
      pagy(:countless, collection, **keyword_args)
    else
      pagy(collection, **keyword_args)
    end
  end

  private

  def with_locale(&)
    return yield unless current_account

    locale   = params[:lang].presence if Rails.env.development?
    locale ||= current_account.locale

    I18n.with_locale(locale, &)
  end

  def with_browser_locale(&)
    return yield if I18n.locale != :'en-US' && I18n.locale != :en

    locale   = params[:lang].presence
    locale ||= request.env['HTTP_ACCEPT_LANGUAGE'].to_s[BROWSER_LOCALE_REGEXP].to_s

    locale =
      if locale.starts_with?('en-') && locale != 'en-US'
        'en-GB'
      else
        locale.split('-').first.presence || 'en-GB'
      end

    locale = 'en-GB' unless I18n.locale_available?(locale)

    I18n.with_locale(locale, &)
  end

  def sign_in_for_demo
    sign_in(User.active.order('random()').take) unless signed_in?
  end

  def current_account
    current_user&.account
  end

  # Whether this signed-in person can actually buy: the billing switch is on,
  # they administer the account, and the account they are billed through is a
  # customer AND is their own — a child account's admin cannot act on the
  # parent's billing page, so the call-to-action sends them to usage instead.
  def billing_available?
    return false unless Docuseal.billing_enabled? && current_account
    return false unless can?(:billing, current_account)

    billing = Plans.billing_account(current_account)

    billing.customer? && billing == current_account
  end

  # Where an upgrade call-to-action goes. The billing page when there is one
  # to go to, the usage page otherwise — never a dead link, and never a link
  # that lands the visitor on a refusal.
  def upgrade_cta_path
    billing_available? ? settings_billing_path : Quotas::USAGE_PATH
  end

  def test_mode_available?
    !true_user.account.customer?
  end

  def refuse_customer_test_mode
    return false if test_mode_available?

    if request.format.html?
      redirect_back fallback_location: root_path, alert: I18n.t('test_mode_is_not_available_on_this_account')
    else
      head :forbidden
    end

    true
  end

  # Signed, non-expiring proxy URL for an account's custom logo, or nil when none is set.
  def account_logo_url(account)
    return unless account&.logo&.attached?

    ActiveStorage::Blob.proxy_url(account.logo.blob)
  end

  def true_ability
    @true_ability ||= Ability.new(true_user)
  end

  def maybe_redirect_to_setup
    redirect_to setup_index_path unless User.exists?
  end

  def button_title(title: I18n.t('submit'), disabled_with: I18n.t('submitting'), title_class: '', icon: nil,
                   icon_disabled: nil)
    render_to_string(partial: 'shared/button_title',
                     locals: { title:, disabled_with:, title_class:, icon:, icon_disabled: })
  end

  def svg_icon(icon_name, class: '')
    render_to_string(partial: "icons/#{icon_name}", locals: { class: })
  end

  def form_link_host
    Docuseal.default_url_options[:host]
  end

  def set_csp
    request.content_security_policy = current_content_security_policy.tap do |policy|
      policy.default_src :self
      policy.script_src :self
      policy.style_src :self, :unsafe_inline
      policy.img_src :self, :https, :http, :blob, :data
      policy.font_src :self, :https, :http, :blob, :data
      policy.manifest_src :self
      policy.media_src :self
      policy.frame_src :self
      policy.worker_src :self, :blob
      policy.connect_src :self

      policy.directives['connect-src'] << 'ws:' if Rails.env.development?
    end
  end
end
