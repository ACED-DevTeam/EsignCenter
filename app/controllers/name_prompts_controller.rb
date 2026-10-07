# frozen_string_literal: true

# "What's your name?" — asked once, of the admin whose account is still named
# after their email address (Registrations.name_missing?). The dashboard sends
# them here; saving fills in their own name and the account name signers see
# on every email, and the question never comes back. Anybody else who opens
# the page is simply sent on to the dashboard.
class NamePromptsController < ApplicationController
  before_action do
    authorize!(:update, current_account)
  end

  before_action :redirect_unless_name_missing

  def show
    @name = current_user.full_name
  end

  def create
    @name = params[:name].to_s.squish

    if Registrations.complete_name!(current_user, @name)
      redirect_to root_path, notice: I18n.t('name_prompt_saved')
    else
      @error_message = I18n.t('name_prompt_name_required')

      render :show, status: :unprocessable_content
    end
  end

  private

  def redirect_unless_name_missing
    redirect_to root_path unless Registrations.name_missing?(current_user)
  end
end
