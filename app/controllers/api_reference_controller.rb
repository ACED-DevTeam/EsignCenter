# frozen_string_literal: true

# The public API reference: /docs/api renders it, /docs/openapi.json is the
# machine-readable description it reads (lib/openapi_document.rb).
#
# Public in the same way the marketing and legal pages are — no login, no
# first-run redirect, no authorization check. API documentation that only a
# customer can read cannot help somebody decide to become one, and the
# document describes doors that are token-authenticated anyway: reading it
# grants nothing.
#
# The reference itself is Scalar (@scalar/api-reference), bundled through
# shakapacker as its own pack (app/javascript/api_reference.js) so the rest of
# the application never carries it, and served from this origin so it runs
# under the application's `script_src :self` policy with no CDN.
class ApiReferenceController < ApplicationController
  layout 'marketing'

  skip_before_action :maybe_redirect_to_setup
  skip_before_action :authenticate_user!
  skip_authorization_check

  around_action :with_english

  def show; end

  def spec
    expires_in OpenapiDocument::CACHE_MAX_AGE, public: true

    render json: OpenapiDocument.json
  end
end
