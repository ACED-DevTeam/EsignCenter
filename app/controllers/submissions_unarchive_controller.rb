# frozen_string_literal: true

class SubmissionsUnarchiveController < ApplicationController
  load_and_authorize_resource :submission

  # Unarchiving puts a document back out for signature, which is what the
  # free plan's open-documents cap counts: it is decided under the same
  # creation lock and refused the same way as creating one would be.
  def create
    authorize!(:update, @submission)

    Quotas.with_creation_lock(@submission.account) do
      @submission.update!(archived_at: nil)

      Quotas.assert_reopen_within_in_flight!(@submission)
    end

    Quotas.record_paid_signals(@submission.account)

    redirect_to submission_path(@submission), notice: I18n.t('submission_has_been_unarchived')
  rescue Quotas::LimitReached => e
    redirect_to submission_path(@submission), alert: e.localized_message
  end
end
