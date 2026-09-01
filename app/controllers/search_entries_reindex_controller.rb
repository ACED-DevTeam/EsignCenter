# frozen_string_literal: true

class SearchEntriesReindexController < ApplicationController
  def create
    authorize!(:manage, EncryptedConfig)

    # The fulltext toggle is instance-global storage (it writes onto the
    # lowest-id account), so a customer tenant must never reach it — that
    # would be a cross-tenant write. Session 2 makes this an operator surface.
    return refuse_customer_reindex if current_account.customer?

    ReindexAllSearchEntriesJob.perform_async

    AccountConfig.find_or_initialize_by(account_id: Account.minimum(:id), key: :fulltext_search)
                 .update!(value: true)

    Docuseal.instance_variable_set(:@fulltext_search, nil)

    redirect_back(fallback_location: settings_account_path,
                  notice: "Started building search index. Visit #{root_url}jobs/busy to check progress.")
  end

  private

  def refuse_customer_reindex
    if request.format.html?
      redirect_back fallback_location: settings_account_path,
                    alert: 'Search index rebuilds are unavailable for customer accounts'
    else
      head :forbidden
    end
  end
end
