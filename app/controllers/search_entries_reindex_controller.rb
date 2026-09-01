# frozen_string_literal: true

# Operator surface: the fulltext index is instance-global, so only a platform
# operator (with 2FA) may build it or flip the toggle.
class SearchEntriesReindexController < ApplicationController
  skip_authorization_check

  # Prepended so an anonymous request meets the 404 before Devise can answer
  # with a sign-in redirect: the surface must not exist for anyone else.
  prepend_before_action :require_operator_access!

  def create
    ReindexAllSearchEntriesJob.perform_async

    OperatorConfigs.set!(:fulltext_search, true)

    Docuseal.refresh_fulltext_search!

    redirect_back(fallback_location: settings_account_path,
                  notice: "Started building search index. Visit #{root_url}jobs/busy to check progress.")
  end
end
