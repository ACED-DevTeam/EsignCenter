# frozen_string_literal: true

# The "Product" numbers on /admin: read from the tables the product already
# keeps, counted for real customers only.
RSpec.describe MarketingAdmin::Product do
  let(:today) { MarketingAdmin.today }

  def account_on(day, **attributes)
    create(:account, created_at: MarketingAdmin.day_range(day).first + 10.hours, **attributes)
  end

  it 'counts new customer accounts by Chicago day, leaving out internal, test-mode and team accounts' do
    account_on(today)
    account_on(today - 3)
    account_on(today - 10)
    account_on(today - 40)
    create(:account, :internal)
    create(:account, :operator)
    create(:account, :with_testing_account, created_at: 50.days.ago)
    create(:account, :with_teams, created_at: 50.days.ago)

    expect(described_class.report[:accounts]).to eq(today: 1, last7: 2, previous7: 1, last30: 3, all_time: 6)
  end

  it 'puts an account made late in the evening in Chicago on that Chicago day' do
    travel_to(Time.utc(2026, 11, 22, 3, 30)) do
      create(:account)

      report = described_class.report

      expect(report[:accounts][:today]).to eq(1)
      expect(report[:daily].last).to include(day: Date.new(2026, 11, 21), accounts: 1)
    end
  end

  def subscription!(account, state, stripe: true, **attributes)
    create(:account_subscription, account:, access_state: state,
                                  stripe_subscription_id: (stripe ? "sub_#{SecureRandom.hex(6)}" : nil), **attributes)
  end

  # Stripe's event as the inbox keeps it. `subscription` is the row (or the
  # bare id) the event is about; a "created" event names it in data.object.id.
  def stripe_event!(account, type, at:, subscription: nil, payload: nil)
    id = subscription.respond_to?(:stripe_subscription_id) ? subscription.stripe_subscription_id : subscription
    payload ||= { type:, data: { object: { id:, object: 'subscription' } } }.to_json

    StripeEventInbox.create!(stripe_event_id: "evt_#{SecureRandom.hex(8)}", event_type: type, payload:,
                             status: StripeEventInbox::PROCESSED, account_id: account&.id, stripe_created_at: at)
  end

  def created!(account, subscription, at:)
    stripe_event!(account, 'customer.subscription.created', at:, subscription:)
  end

  describe 'paid plans' do
    it 'counts subscriptions Stripe is running, with trials told apart' do
      subscription!(create(:account), 'active')
      subscription!(create(:account), 'trialing')
      subscription!(create(:account), 'past_due')
      subscription!(create(:account), 'canceling')
      subscription!(create(:account), 'cancelled')
      subscription!(create(:account), 'suspended')
      subscription!(create(:account, :internal), 'active')

      expect(described_class.report[:paid]).to include(total: 4, paying: 3, trialing: 1, past_due: 1, canceling: 1,
                                                       complimentary: 0)
    end

    # `rake plans:grant` and the operator console give paid access by hand.
    # With an end date or without one, nobody bought it.
    it 'never counts paid access given by hand as purchased, permanent or not' do
      Plans::Manual.grant!(create(:account))
      Plans::Manual.grant!(create(:account), comp_expires_at: 30.days.from_now)
      subscription!(create(:account), 'active')

      expect(described_class.report[:paid]).to include(total: 1, paying: 1, complimentary: 2, new_this_week: 0)
    end
  end

  # "New paid plans, last 7 days": a subscription — the trial or the plan
  # itself — that Stripe created in the window, and that is the one the
  # account's row holds. Counted even if it has ended since.
  describe 'new paid plans in the last 7 days' do
    def new_this_week
      described_class.report[:paid][:new_this_week]
    end

    it 'counts a plan on the day Stripe says its trial or subscription was created' do
      this_week = create(:account)
      long_ago = create(:account)
      # Rows are written when checkout is first opened, which says nothing
      # about when anything was bought: both of these rows are old.
      started_this_week = subscription!(this_week, 'trialing', created_at: 2.years.ago)
      started_long_ago = subscription!(long_ago, 'active', created_at: 2.years.ago)

      created!(this_week, started_this_week, at: 2.days.ago)
      created!(long_ago, started_long_ago, at: 40.days.ago)
      # A renewal or a change to a plan is not a start.
      stripe_event!(long_ago, 'customer.subscription.updated', at: 1.day.ago, subscription: started_long_ago)
      stripe_event!(long_ago, 'invoice.paid', at: 1.day.ago, subscription: started_long_ago)

      expect(new_this_week).to eq(1)
    end

    # The review's case. A customer of three years opens checkout twice;
    # Stripe creates a second subscription, the app cancels and refunds it,
    # and the row never points at it. Its "created" event is real, is stamped
    # with the account, and is this week's.
    it 'does not count a long-standing customer whose duplicate subscription was created and cancelled' do
      customer = create(:account)
      original = subscription!(customer, 'active', created_at: 3.years.ago)

      created!(customer, original, at: 3.years.ago)
      created!(customer, 'sub_the_duplicate', at: 1.day.ago).update!(last_error: 'duplicate subscription')

      expect(original.reload.stripe_subscription_id).not_to eq('sub_the_duplicate')
      expect(new_this_week).to eq(0)
      expect(described_class.report[:paid][:total]).to eq(1)
    end

    it 'counts a returning customer whose new subscription replaced an old one' do
      returning = create(:account)
      current = subscription!(returning, 'active', created_at: 2.years.ago)

      created!(returning, 'sub_from_two_years_ago', at: 2.years.ago)
      created!(returning, current, at: 1.day.ago)

      expect(new_this_week).to eq(1)
    end

    it 'counts a plan that started this week even though it has already ended' do
      gone = create(:account)
      ended = subscription!(gone, 'cancelled')

      created!(gone, ended, at: 2.days.ago)

      expect(new_this_week).to eq(1)
      # It started; it is not running. The two numbers answer different questions.
      expect(described_class.report[:paid][:total]).to eq(0)
    end

    it 'counts an account once, however many times Stripe delivered the event' do
      account = create(:account)
      subscription = subscription!(account, 'active')

      3.times { created!(account, subscription, at: 1.day.ago) }

      expect(new_this_week).to eq(1)
    end

    it 'does not count access given by hand, a checkout nobody finished, or the platform’s own accounts' do
      Plans::Manual.grant!(create(:account))
      abandoned = create(:account)
      subscription!(abandoned, 'cancelled', stripe: false, created_at: 1.day.ago)
      internal = create(:account, :internal)
      created!(internal, subscription!(internal, 'active'), at: 1.day.ago)

      expect(new_this_week).to eq(0)
    end

    it 'does not count an event it cannot tie to a subscription the account holds' do
      account = create(:account)
      subscription = subscription!(account, 'active')

      created!(nil, subscription, at: 1.day.ago)
      stripe_event!(account, 'customer.subscription.created', at: 1.day.ago, payload: '{"data":{}}')
      stripe_event!(account, 'customer.subscription.created', at: 1.day.ago, payload: 'not json at all')
      stripe_event!(account, 'customer.subscription.created', at: 1.day.ago, payload: '[]')

      expect(new_this_week).to eq(0)
    end

    it 'uses Stripe’s time for the event, and Chicago’s days for the window' do
      account = create(:account)
      subscription = subscription!(account, 'active')
      # Delivered today, about a subscription Stripe created eight days ago.
      created!(account, subscription, at: 8.days.ago).update_columns(created_at: Time.current)

      expect(new_this_week).to eq(0)
    end
  end

  describe 'documents' do
    let(:account) { create(:account, :with_testing_account) }
    let(:author) { create(:user, account:) }
    let(:template) { create(:template, account:, author:) }

    # A document with a signer for each given completion time; nil is a
    # signer who has not signed.
    def document!(*completions, declined: false, created_at: Time.current)
      submission = create(:submission, template:, created_by_user: author, created_at:)

      completions.each do |completed_at|
        create(:submitter, submission:, account_id: account.id, uuid: SecureRandom.uuid, completed_at:,
                           declined_at: (Time.current if declined && completed_at.nil?))
      end

      submission
    end

    def at(day, hour = 12)
      MarketingAdmin.day_range(day).first + hour.hours
    end

    it 'counts documents sent on the day they were sent, leaving out test-mode copies' do
      document!(nil)
      document!(nil, created_at: at(today - 2))
      testing = account.testing_accounts.first
      testing_author = create(:user, account: testing)
      create(:submission, template: create(:template, account: testing, author: testing_author),
                          created_by_user: testing_author)

      report = described_class.report

      expect(report[:sent]).to include(today: 1, last7: 2, last30: 2)
      expect(report[:daily].last).to include(day: today, sent: 1)
    end

    it 'counts a document once, on the day its LAST signer finished' do
      document!(at(today - 5), at(today - 2), created_at: at(today - 6))
      document!(at(today - 2), created_at: at(today - 2))

      report = described_class.report
      by_day = report[:daily].to_h { |day| [day[:day], day[:completed]] }

      expect(by_day[today - 5]).to eq(0)
      expect(by_day[today - 2]).to eq(2)
      expect(report[:completed]).to include(today: 0, last7: 2, last30: 2)
    end

    it 'does not count a document while one signer has not signed, or when one declined' do
      document!(at(today - 3), nil)
      document!(at(today - 3), nil, declined: true)
      document!(nil)

      expect(described_class.report[:completed]).to include(today: 0, last7: 0, last30: 0)
    end

    it 'counts it the moment the last signer does sign, on that day' do
      waiting = document!(at(today - 3), nil, created_at: at(today - 4))

      expect(described_class.report[:completed][:last30]).to eq(0)

      waiting.submitters.find_by(completed_at: nil).update!(completed_at: at(today))

      report = described_class.report

      expect(report[:completed]).to include(today: 1, last7: 1)
      expect(report[:daily].find { |day| day[:day] == today - 3 }).to include(completed: 0)
    end

    it 'files a late-evening completion under the Chicago day, and ignores the plan-limit rows' do
      travel_to(Time.utc(2026, 11, 22, 3, 30)) do
        submission = document!(Time.current)
        # What the plan limits count (the FIRST signer) is a different number
        # and is not what this page reads.
        CompletedSubmitter.create!(account:, submission:, submitter: submission.submitters.first,
                                   completed_at: 3.days.ago, is_first: true, sms_count: 0, source: 'invite')

        report = described_class.report

        expect(report[:daily].last).to include(day: Date.new(2026, 11, 21), completed: 1)
        expect(report[:completed][:last30]).to eq(1)
      end
    end

    it 'covers thirty days' do
      expect(described_class.report[:daily].size).to eq(30)
    end
  end
end
