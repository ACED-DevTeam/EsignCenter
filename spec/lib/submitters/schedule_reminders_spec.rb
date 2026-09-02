# frozen_string_literal: true

describe Submitters::ScheduleReminders do
  let(:account) { create(:account, :paid) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:) }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: author) }
  let(:submitter) { submission.submitters.first }

  before { submitter.update!(sent_at: Time.current) }

  def configure_reminders(value)
    account.account_configs.create!(key: AccountConfig::SUBMITTER_REMINDERS, value:)
  end

  it 'schedules one reminder job per configured duration, with the right index' do
    configure_reminders('first_duration' => 'two_days', 'second_duration' => 'seven_days', 'third_duration' => '')

    expect { described_class.call(submitter) }
      .to change(SendSubmitterInvitationReminderEmailJob.jobs, :size).by(2)

    indices = SendSubmitterInvitationReminderEmailJob.jobs.map { |job| job['args'].first['reminder_index'] }
    expect(indices).to contain_exactly(1, 2)
  end

  it 'schedules nothing when reminders are not configured' do
    expect { described_class.call(submitter) }
      .not_to change(SendSubmitterInvitationReminderEmailJob.jobs, :size)
  end

  it 'schedules nothing for an account whose plan lacks reminders, even with a reminders row' do
    configure_reminders('first_duration' => 'two_days')
    account.account_configs.find_by(key: AccountConfig::PLAN_STUB_KEY).destroy!

    expect { described_class.call(submitter) }
      .not_to change(SendSubmitterInvitationReminderEmailJob.jobs, :size)
  end

  it 'schedules nothing when the submitter has not been sent yet' do
    configure_reminders('first_duration' => 'two_days')
    submitter.update!(sent_at: nil)

    expect { described_class.call(submitter) }
      .not_to change(SendSubmitterInvitationReminderEmailJob.jobs, :size)
  end
end
