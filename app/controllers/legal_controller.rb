# frozen_string_literal: true

# The two public legal documents: /terms and /privacy.
#
# Public in the same way /verify is (VerifyController): no login, no
# first-run setup redirect, no authorization check. Somebody reading the Terms
# before they sign up has no account, and somebody who has just been emailed a
# link to a document has no reason to make one.
#
# The words themselves live in LegalDocuments (config/legal/*.html.erb) rather
# than in these views, because the same rendered bytes are what every
# acceptance row is hashed against — a document that only existed as a view
# could not be produced again once it changed.
class LegalController < ApplicationController
  layout 'marketing'

  skip_before_action :maybe_redirect_to_setup
  skip_before_action :authenticate_user!
  skip_authorization_check

  # English-only, like the marketing pages (ApplicationController#with_english).
  around_action :with_english

  def terms; end

  def privacy; end
end
