# frozen_string_literal: true

# The numbers the spec sheet decided, pinned LITERALLY (checkpoint 10, B5).
#
# Every other spec in the suite reads these through the constant —
# `BillingLifecycle::INVITE_TOKEN_DAYS.days.from_now`, "valid for
# #{…}" — which is right, because a spec that hard-codes a number in twenty
# places is a spec nobody can change. But it leaves one hole: change the
# constant and the whole suite agrees with the new value. Terms of Service, the
# help centre, the pricing page and the usage page all render from these too,
# so they would agree as well, and a silent change to a number a customer is
# being sold on would pass everything.
#
# So this file is the one place a number is written down twice on purpose. It
# asserts nothing about behaviour — the behaviour is proved elsewhere — only
# that the value still is what plans/esigncenter-standalone/spec.md says it is.
# One example per number, each citing spec.md "Constants" and its D-number, so
# a failure here names the decision that has to be revisited rather than a line
# of code.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Spec constants', type: :lib do
  # spec.md line 26 (D16/D29/D41/D45): free = 5 docs/month, counted at first
  # signer completion, with the warning email at 4/5.
  it 'counts a free month at 5 completed documents, and warns at 4' do
    expect(Quotas::Limits::FREE_COMPLETIONS_PER_MONTH).to eq(5)
    expect(Quotas::Limits::FREE_COMPLETIONS_WARNING_AT).to eq(4)
  end

  # spec.md "Constants" (D42/D63): free sends — 15 per UTC month, hard block.
  it 'stops a free account at 15 documents sent in a month' do
    expect(Quotas::Limits::FREE_SENDS_PER_MONTH).to eq(15)
  end

  # spec.md "Constants" (D42): free in-flight 10, hard.
  it 'stops a free account at 10 documents open at once' do
    expect(Quotas::Limits::FREE_IN_FLIGHT).to eq(10)
  end

  # spec.md line 26 (D16): free is one seat.
  it 'gives a free account one seat' do
    expect(Quotas::Limits::FREE_SEATS).to eq(1)
  end

  # spec.md "Constants" (D46/D57): storage — free 1 GB, paid 10 GB per seat,
  # blocking new uploads only and never sending, with an 80% warning.
  it 'gives a free account 1 GB of storage and a paid one 10 GB per seat, warning at 80%' do
    expect(Quotas::Limits::FREE_STORAGE_BYTES).to eq(1_073_741_824)
    expect(Quotas::Limits::FREE_STORAGE_BYTES).to eq(1.gigabyte)
    expect(Quotas::Limits::PAID_STORAGE_BYTES_PER_SEAT).to eq(10_737_418_240)
    expect(Quotas::Limits::PAID_STORAGE_BYTES_PER_SEAT).to eq(10.gigabytes)
    expect(Quotas::Limits::WARNING_FRACTION).to eq(0.8)
  end

  # spec.md "Constants" (D46/D57): paid velocity 200 sends/day/seat — a
  # warn-flag for the operator, never a block (D42).
  it 'flags a paid account for review above 200 sends a day per seat' do
    expect(Quotas::Limits::PAID_SENDS_PER_DAY_PER_SEAT).to eq(200)
  end

  # spec.md "Constants" (D46/D57): paid in-flight 50 x seats, warn-flag.
  it 'flags a paid account for review above 50 documents open at once per seat' do
    expect(Quotas::Limits::PAID_IN_FLIGHT_PER_SEAT).to eq(50)
  end

  # spec.md line 37 (the plan table): paid completions — unlimited, with a
  # 500-per-seat fair-use review threshold.
  it 'flags a paid account for review above 500 completions a month per seat' do
    expect(Quotas::Limits::PAID_COMPLETIONS_REVIEW_PER_SEAT).to eq(500)
  end

  # spec.md line 27 (D5/D15/D44): $10/user/month on a 14-day trial.
  it 'gives a new subscription a 14-day trial' do
    expect(StripeBilling::TRIAL_PERIOD_DAYS).to eq(14)
  end

  # spec.md "Constants" + line 63 (D43/D57): past-due grace 14 days, dunning
  # emails on days 0, 3, 7 and 13 of it.
  it 'gives a past-due account 14 days of grace, with dunning on days 0, 3, 7 and 13' do
    expect(BillingLifecycle::PAST_DUE_GRACE_DAYS).to eq(14)
    expect(BillingLifecycle::DUNNING_DAYS).to eq([0, 3, 7, 13])
  end

  # spec.md "Constants" (D57): an invitation's token is good for 7 days, after
  # which the seat it was holding is handed back.
  it 'expires an invitation token after 7 days' do
    expect(BillingLifecycle::INVITE_TOKEN_DAYS).to eq(7)
  end

  # spec.md line 64 (D43): purge only after 1 year dormant, with warnings 60,
  # 30 and 7 days before it.
  it 'calls an account dormant after a year, and warns 60, 30 and 7 days before the purge' do
    expect(Accounts::Retention::DORMANT_AFTER).to eq(1.year)
    expect(Accounts::Retention::DORMANT_WARNING_DAYS).to eq([60, 30, 7])
    expect(Accounts::Retention::FINAL_WARNING_DAYS).to eq(7)
  end

  # spec.md line 64 (D43): a cancelled paid account keeps its data at least a
  # year after the subscription ended, whatever the sign-in dates say.
  it 'keeps a cancelled paid account\'s data for a year after the subscription ended' do
    expect(Accounts::Retention::PAID_RETENTION).to eq(1.year)
  end

  # spec.md line 64 (D43): explicit self-deletion has a 90-day recovery
  # window, with one reminder a week before the date.
  it 'gives an account somebody deleted 90 days to change their mind, with a reminder a week out' do
    expect(Accounts::Deletion::WINDOW_DAYS).to eq(90)
    expect(Accounts::Retention::DELETION_REMINDER_DAYS).to eq(7)
  end
end
# rubocop:enable RSpec/DescribeClass
