# frozen_string_literal: true

# The Cloudflare Turnstile half of a public form (lib/turnstile.rb): the widget
# the page carries, and the server-side check of the token it produces.
#
# Two forms use it — sign-up (RegistrationsController) and the support form
# (SupportRequestsController) — and both are anonymous doors that cost us real
# work, so the rules live here once rather than being copied and drifting:
#
#   * the third-party host is named ONCE, and the policy that allows it is
#     widened only on the GET that renders the widget. `set_csp` itself runs
#     only on a non-Turbo GET (ApplicationController), so this callback runs
#     after it on exactly those requests and appends to the policy the
#     response will actually carry. A POST re-rendering the form has no policy
#     of its own to widen, and no other page in the application ever allows a
#     third-party script.
#   * a failed verification is a plain false. What to SAY about it — a form
#     error, a refusal page — belongs to the controller, because the two forms
#     word it differently.
#
# There is no environment bypass: the verification request is made in the test
# suite too, and is stubbed (spec/support/turnstile_helpers.rb).
module TurnstileProtected
  extend ActiveSupport::Concern

  TURNSTILE_HOST = 'https://challenges.cloudflare.com'

  included do
    helper_method :turnstile_widget?
  end

  class_methods do
    # Widen the security policy on the actions that RENDER the widget — and
    # only when there IS a widget: an instance with no site key draws none, so
    # its policy stays as tight as every other page's.
    def protect_with_turnstile(only:)
      widget_is_rendered = lambda do
        Turnstile.widget? && request.get? && !request.headers['HTTP_X_TURBO']
      end

      before_action :allow_turnstile, only:, if: widget_is_rendered
    end
  end

  private

  def turnstile_widget?
    Turnstile.widget?
  end

  def turnstile_passed?
    Turnstile.verify!(params['cf-turnstile-response'], request.remote_ip)

    true
  rescue Turnstile::VerificationFailed
    false
  end

  def allow_turnstile
    policy = request.content_security_policy

    return unless policy

    policy.script_src(*policy.directives['script-src'], TURNSTILE_HOST)
    policy.frame_src(*policy.directives['frame-src'], TURNSTILE_HOST)
  end
end
