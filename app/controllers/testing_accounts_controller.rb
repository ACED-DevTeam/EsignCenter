# frozen_string_literal: true

class TestingAccountsController < ApplicationController
  skip_authorization_check only: :destroy

  def create
    authorize!(:manage, current_account)
    authorize!(:manage, current_user)

    return refuse_customer_test_mode if true_user.account.customer?

    impersonate_user(Accounts.find_or_create_testing_user(true_user.account))

    redirect_back(fallback_location: root_path)
  end

  def destroy
    stop_impersonating_user

    redirect_back(fallback_location: root_path)
  end

  private

  def refuse_customer_test_mode
    if request.format.html?
      redirect_back fallback_location: root_path, alert: 'Test mode is unavailable for customer accounts'
    else
      head :forbidden
    end
  end
end
