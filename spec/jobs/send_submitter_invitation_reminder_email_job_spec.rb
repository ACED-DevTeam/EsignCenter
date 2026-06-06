# frozen_string_literal: true

describe SendSubmitterInvitationReminderEmailJob do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:) }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: author, source: 'api') }
  let(:submitter) { submission.submitters.first }
  let(:mail) { instance_double(ActionMailer::MessageDelivery, deliver_now!: true) }

  before do
    submitter.update!(sent_at: 2.days.ago)
    allow(SubmitterMailer).to receive(:invitation_email).with(submitter).and_return(mail)
  end

  def perform(index = 1)
    described_class.new.perform('submitter_id' => submitter.id, 'reminder_index' => index)
  end

  def reminder_events
    SubmissionEvent.where(submitter_id: submitter.id, event_type: 'send_reminder_email')
  end

  it 'sends a reminder and records an indexed event for a pending submitter' do
    expect { perform(1) }.to change(reminder_events, :count).by(1)

    expect(mail).to have_received(:deliver_now!)
    expect(reminder_events.first.data['reminder_index']).to eq(1)
  end

  it 'does not send once the submitter has completed' do
    submitter.update!(completed_at: Time.current)

    expect { perform(1) }.not_to change(reminder_events, :count)
    expect(mail).not_to have_received(:deliver_now!)
  end

  it 'does not send once the submitter has declined' do
    submitter.update!(declined_at: Time.current)

    expect { perform(1) }.not_to change(reminder_events, :count)
    expect(mail).not_to have_received(:deliver_now!)
  end

  it 'does not resend a reminder slot that was already sent (idempotent)' do
    SubmissionEvent.create!(submitter:, event_type: 'send_reminder_email', data: { 'reminder_index' => 1 })

    expect { perform(1) }.not_to change(reminder_events, :count)
    expect(mail).not_to have_received(:deliver_now!)
  end

  it 'still sends a different reminder slot' do
    SubmissionEvent.create!(submitter:, event_type: 'send_reminder_email', data: { 'reminder_index' => 1 })

    expect { perform(2) }.to change(reminder_events, :count).by(1)
    expect(mail).to have_received(:deliver_now!)
  end

  it 'sends a reminder slot at most once across retries or duplicate jobs' do
    expect do
      perform(1)
      perform(1)
    end.to change(reminder_events, :count).by(1)

    expect(mail).to have_received(:deliver_now!).once
  end

  it 'does not send for an expired submission' do
    submission.update!(expire_at: 1.day.ago)

    expect { perform(1) }.not_to change(reminder_events, :count)
    expect(mail).not_to have_received(:deliver_now!)
  end

  it 'does not send for an archived submission' do
    submission.update!(archived_at: Time.current)

    expect { perform(1) }.not_to change(reminder_events, :count)
    expect(mail).not_to have_received(:deliver_now!)
  end

  it 'releases the claim when delivery fails so a retry can re-send' do
    allow(mail).to receive(:deliver_now!).and_raise(StandardError, 'smtp unavailable')

    expect { perform(1) }.to raise_error(StandardError)
    expect(reminder_events.count).to eq(0)

    allow(mail).to receive(:deliver_now!).and_return(true)

    expect { perform(1) }.to change(reminder_events, :count).by(1)
  end
end
