# frozen_string_literal: true

module Api
  class UsersController < ApiBaseController
    # Authorize the person this request is actually FOR, not the `@current_user`
    # ivar. Devise fills that ivar with the signed-in human while `current_user`
    # is whoever is being impersonated (test mode, or a support session), so the
    # two are not the same person and the action renders the second one.
    before_action { authorize!(:read, current_user) }

    def show
      render json: current_user.as_json(only: %i[id first_name last_name email])
    end
  end
end
