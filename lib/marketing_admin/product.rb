# frozen_string_literal: true

module MarketingAdmin
  # The "Product" section of /admin: what the marketing is for. New accounts,
  # paid plans, and documents sent and completed, read from the tables the
  # product already keeps. Nothing new is tracked for this page and nothing
  # here is about a signer: every figure is a count of accounts or documents.
  module Product
    SERIES_DAYS = 30
    SUBSCRIPTION_CREATED = 'customer.subscription.created'

    module_function

    # Real customers' own accounts: not the platform's internal accounts, not
    # the test-mode copy of an account, and not the extra team accounts a
    # customer adds under their own.
    def signup_accounts
      Account.where(account_kind: Account::CUSTOMER_KIND)
             .where.not(id: AccountLinkedAccount.select(:linked_account_id))
    end

    # Accounts whose documents count: customers and their team accounts, but
    # never a test-mode copy.
    def document_accounts
      Account.where(account_kind: Account::CUSTOMER_KIND).where.not(id: Account.testing_child_ids)
    end

    def report(today: MarketingAdmin.today)
      days = ((today - (SERIES_DAYS - 1))..today).to_a
      window = MarketingAdmin.day_range(days.first, today)
      accounts = per_day(signup_accounts.where(created_at: window), 'accounts.created_at')
      sent = per_day(Submission.where(account_id: document_accounts.select(:id), created_at: window),
                     'submissions.created_at')
      completed = completed_per_day(window)

      {
        accounts: series(days, accounts).merge(all_time: signup_accounts.count),
        sent: series(days, sent),
        completed: series(days, completed),
        daily: days.map do |day|
          { day:, accounts: accounts.fetch(day, 0), sent: sent.fetch(day, 0), completed: completed.fetch(day, 0) }
        end,
        paid: paid(today)
      }
    end

    # A document is completed when EVERY signer has finished it, and it is
    # counted on the day the last of them did — the app's own test for
    # "finished" (no signer left without a completion). A document two people
    # sign on different days counts once, on the second day; one that somebody
    # never signs, or declines, does not count at all.
    #
    # This is deliberately NOT the number the plan limits use
    # (CompletedSubmitter#is_first), which charges a document to the month its
    # FIRST signer finishes. That answers "what has this account used"; this
    # answers "how many documents got done".
    def completed_per_day(window)
      finished = Submitter.where(account_id: document_accounts.select(:id))
                          .where(submission_id: Submitter.where(completed_at: window).select(:submission_id))
                          .group(:submission_id)
                          .having('COUNT(*) = COUNT(submitters.completed_at)')
                          .having('MAX(submitters.completed_at) >= ? AND MAX(submitters.completed_at) < ?',
                                  window.first, window.last)
                          .select('MAX(submitters.completed_at) AS finished_at')

      Submitter.from(finished, :finished)
               .group(Arel.sql(MarketingAdmin.chicago_day_sql('finished.finished_at'))).count
    end

    def per_day(scope, column)
      scope.group(Arel.sql(MarketingAdmin.chicago_day_sql(column))).count
    end

    def series(days, counts)
      on = ->(day) { counts.fetch(day, 0) }

      { today: on.call(days.last), last7: days.last(7).sum(&on), previous7: days.last(14).first(7).sum(&on),
        last30: days.sum(&on) }
    end

    # Paid plans, as PURCHASED: a subscription Stripe is running, in one of the
    # states the app treats as paid (Plans::PAID_ACCESS_STATES — a trial, a
    # live subscription, one cancelling at period end, one whose renewal is
    # late). Paid access the operator gave away by hand, with an end date or
    # without one, has no Stripe subscription behind it: it is listed apart as
    # complimentary and never counted as bought.
    def paid(today)
      live = AccountSubscription.where(account_id: signup_accounts.select(:id),
                                       access_state: Plans::PAID_ACCESS_STATES)
      bought = live.where.not(stripe_subscription_id: [nil, ''])
      by_state = bought.group(:access_state).count

      {
        total: by_state.values.sum,
        paying: by_state.except('trialing').values.sum,
        trialing: by_state.fetch('trialing', 0),
        past_due: by_state.fetch('past_due', 0),
        canceling: by_state.fetch('canceling', 0),
        complimentary: live.where(stripe_subscription_id: [nil, '']).count,
        new_this_week: started(MarketingAdmin.day_range(today - 6, today))
      }
    end

    # "New paid plans, last 7 days": customer accounts whose subscription — the
    # trial or the paid plan itself — was CREATED in the window. Counted even
    # if it has ended since: it is a count of plans that started, not of plans
    # still running ("Paid plans now" is that).
    #
    # Two things make a start real, and both are checked:
    #
    #   * WHEN comes from Stripe's own "subscription created" event, at the
    #     time Stripe stamped it. Not from when our row was written — that
    #     happens when somebody first opens checkout, paid or not, and a
    #     returning customer's row can be years old;
    #   * WHICH has to be the subscription the account's row actually holds.
    #     Stripe can create a second subscription for a customer who already
    #     has one (a double checkout); the app cancels and refunds it and the
    #     row never points at it (StripeBilling::Linker). Its "created" event
    #     is real, and without this check a customer of three years would be
    #     counted as newly paid this week.
    def started(window)
      created = StripeEventInbox.where(event_type: SUBSCRIPTION_CREATED).where.not(account_id: nil)
                                .where('COALESCE(stripe_created_at, created_at) >= ? AND ' \
                                       'COALESCE(stripe_created_at, created_at) < ?', window.first, window.last)
                                .filter_map { |event| [event.account_id, subscription_id(event)] }
      held = AccountSubscription.where(account_id: signup_accounts.where(id: created.map(&:first)).select(:id))
                                .pluck(:account_id, :stripe_subscription_id).to_h

      created.select { |account_id, id| id.present? && held[account_id] == id }.map(&:first).uniq.size
    end

    # The id of the subscription a "created" event is about. An event whose
    # payload cannot be read (a purged account's is scrubbed) names none.
    def subscription_id(event)
      event.event_object['id'].to_s
    rescue StandardError
      nil
    end
  end
end
