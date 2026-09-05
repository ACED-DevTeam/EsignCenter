# frozen_string_literal: true

module Operator
  # The abuse queue: every flag the platform has raised, across every account,
  # newest first.
  #
  # A flag is a thing to LOOK AT, never a thing that acted on its own. Four of
  # the six kinds are pure warnings the quota engine writes (fair use, send
  # velocity, documents in flight) or a signer's report of a document; the
  # other two — complaint and bounce_rate — are written at the moment sending
  # was paused automatically.
  #
  # Which is why the two buttons here are deliberately separate. "Resolve"
  # closes the flag and changes nothing else: a paused account stays paused.
  # "Resume sending" lifts the pause, and SendingPause.resume! resolves the
  # open complaint and bounce_rate flags of that account as part of the same
  # locked write — so resuming resolves those two kinds, and resolving never
  # resumes. Two decisions, two clicks, and the page says so.
  class AbuseFlagsController < BaseController
    KINDS = AbuseFlag::KINDS

    rescue_from Refused, with: :refused

    def index
      load_queue
    end

    # Closes the flag with the operator's own sentence stored on it, so the
    # row itself says who judged it and why — the audit log is the index, the
    # flag is where the verdict lives.
    def resolve
      reason = required_reason
      flag = find_flag!

      raise Refused, t('operator_refused_flag_resolved') if flag.resolved_at.present?

      ApplicationRecord.transaction do
        flag.update!(resolved_at: Time.current,
                     details: flag.details.merge('resolution' => reason,
                                                 'resolved_by' => true_user&.email))

        record!('abuse.resolve', account: flag.account, subject: flag, reason:,
                                 details: { kind: flag.kind, period: flag.period })
      end

      redirect_to operator_abuse_path(filter_params), notice: t('operator_notice_flag_resolved')
    end

    # The same door the account page offers, from the queue: lift the
    # automatic pause after a human has looked at what caused it.
    def resume_sending
      reason = required_reason
      flag = find_flag!
      account = flag.account

      assert_actionable!(account)

      paused_at, = SendingPause.state(account)

      raise Refused, t('operator_refused_not_paused') if paused_at.blank?

      ApplicationRecord.transaction do
        SendingPause.resume!(account)

        record!('sending.resume', account:, reason:, details: { was_paused_at: paused_at.iso8601,
                                                                from: 'abuse_queue' })
      end

      redirect_to operator_abuse_path(filter_params), notice: t('operator_notice_sending_resumed')
    end

    private

    def load_queue
      @kind = params[:kind].to_s.presence_in(KINDS)
      @account = console_accounts.find_by(id: params[:account_id]) if params[:account_id].present?
      @show_resolved = params[:resolved].to_s == 'true'

      # The account each flag names, and the account that PAYS for it: a flag
      # on a child links to (and is acted on through) its parent, so both are
      # loaded for the whole page rather than one query per row.
      flags = AbuseFlag.order(created_at: :desc, id: :desc)
                       .preload(account: [:account_subscription, { linked_account_account: :account }])
      flags = flags.open unless @show_resolved
      flags = flags.where(kind: @kind) if @kind
      flags = flags.where(account_id: @account.id) if @account

      @pagy, @flags = pagy_auto(flags)
      load_subjects
      load_pauses
    end

    # The reported submissions of this page in one query rather than one per
    # row, with the template each belongs to and how many people were asked
    # to sign — everything the row shows about a document report except what
    # the reporter typed, which is on the flag itself.
    def load_subjects
      ids = @flags.filter_map { |flag| flag.subject_id if flag.subject_type == 'Submission' }

      @submissions = Submission.where(id: ids).preload(:template).index_by(&:id)
      @submitter_counts = Submitter.where(submission_id: ids).group(:submission_id).count
    end

    # Which of the flagged accounts are actually paused right now, so the
    # queue can offer "Resume sending" only where there is a pause to lift.
    def load_pauses
      ids = @flags.map { |flag| billing_account_for(flag.account).id }.uniq

      @paused_account_ids = Account.where(id: ids).where.not(sending_paused_at: nil).ids.to_set
    end

    def find_flag!
      AbuseFlag.find_by(id: params[:id]) || raise(Refused, t('operator_refused_flag_missing'))
    end

    # A testing child is not an account of its own on this console — its page
    # is a corner of its parent's — so a flag raised on one links to (and is
    # acted on through) the account that owns it.
    def console_account_for(account)
      testing_child_ids.include?(account.id) ? Plans.billing_account(account) : account
    end

    def billing_account_for(account)
      Plans.billing_account(account)
    end

    def testing_child_ids
      @testing_child_ids ||= Account.testing_child_ids.to_set
    end

    # Keeps the operator where they were: an action taken from a filtered
    # queue comes back to the same filtered queue.
    def filter_params
      params.permit(:kind, :account_id, :resolved, :page).to_h.compact_blank
    end

    def refused(error)
      flash.now[:alert] = error.message

      load_queue

      render :index, status: :unprocessable_content
    end

    def record!(action, account:, reason:, subject: nil, details: {})
      OperatorEvents.record!(operator: true_user, action:, account:, subject:, reason:, details:, request:)
    end

    helper_method :console_account_for, :billing_account_for, :filter_params
  end
end
