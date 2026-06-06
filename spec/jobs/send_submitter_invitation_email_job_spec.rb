# frozen_string_literal: true

describe SendSubmitterInvitationEmailJob do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:) }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: author, source: 'api') }
  let(:submitter) { submission.submitters.first }
  let(:mail) { instance_double(ActionMailer::MessageDelivery, deliver_now!: true) }

  before do
    allow(SubmitterMailer).to receive(:invitation_email).with(submitter).and_return(mail)
    account.account_configs.create!(key: AccountConfig::SUBMITTER_REMINDERS, value: { 'first_duration' => 'two_days' })
  end

  it 'schedules reminders on the first send even when sent_at is pre-set at creation' do
    # The main create flows set sent_at synchronously at creation, before the job runs.
    submitter.update!(sent_at: Time.current)

    expect { described_class.new.perform('submitter_id' => submitter.id) }
      .to change(SendSubmitterInvitationReminderEmailJob.jobs, :size).by(1)
  end

  it 'does not schedule reminders again once an invitation was already sent' do
    SubmissionEvent.create!(submitter:, event_type: 'send_email')

    expect { described_class.new.perform('submitter_id' => submitter.id) }
      .not_to change(SendSubmitterInvitationReminderEmailJob.jobs, :size)
  end
end
