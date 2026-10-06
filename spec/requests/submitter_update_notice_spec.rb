# frozen_string_literal: true

# The one silent throttle in the product tells the user what happened: when
# a recipient edit asks to resend the invitation but one already went out
# within 4 hours, the notice says so instead of a plain "saved".
describe 'Submitter update invitation notice' do
  let(:account) { create(:account) }
  let(:admin) { create(:user, :admin, account:) }
  let(:template) { create(:template, account:, author: admin) }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: admin) }
  let(:submitter) { submission.submitters.first }

  before { sign_in(admin) }

  def update_and_resend
    put "/submitters/#{submitter.id}", params: { submitter: { name: 'Renamed Signer' }, send_email: '1' }

    expect(response).to have_http_status(:redirect)
    expect(submitter.reload.name).to eq('Renamed Signer')
  end

  it 'says the invitation was not resent when one went out within the last 4 hours' do
    create(:email_event, account:, emailable: submitter, email: submitter.email, tag: 'submitter_invitation',
                         event_type: 'send', event_datetime: 1.hour.ago)

    update_and_resend

    expect(flash[:notice]).to eq(I18n.t('invitation_already_sent_recently'))
    expect(flash[:notice]).to include('was not resent')
    expect(Sidekiq::Worker.jobs.pluck('class')).not_to include('SendSubmitterInvitationEmailJob')
  end

  it 'keeps the plain saved notice and resends when the last invitation is older than 4 hours' do
    create(:email_event, account:, emailable: submitter, email: submitter.email, tag: 'submitter_invitation',
                         event_type: 'send', event_datetime: 5.hours.ago, created_at: 5.hours.ago)

    update_and_resend

    expect(flash[:notice]).to eq(I18n.t('changes_have_been_saved'))
    expect(SendSubmitterInvitationEmailJob.jobs.size).to eq(1)
  end
end
