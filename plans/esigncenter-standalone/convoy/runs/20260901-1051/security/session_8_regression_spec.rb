# frozen_string_literal: true

RSpec.describe 'Session 8 security regressions', type: :request do
  let(:account) { create(:account) }
  let!(:admin) { create(:user, :admin, account:) }

  def staged_export
    export = AccountExport.create!(account:, requested_by: admin, status: AccountExport::RUNNING,
                                   started_at: 10.minutes.ago)
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('private account archive'),
                                                filename: 'export.zip', content_type: 'application/zip')
    export.stage_blob!(blob)
    [export, blob]
  end

  it 'purges an uploaded archive that a killed worker never attached' do
    export, blob = staged_export
    account.update!(deletion_requested_at: 90.days.ago, purge_scheduled_for: 1.minute.ago)

    expect(Accounts::Purge.call(account)).to eq(:purged)
    expect(AccountExport.exists?(export.id)).to be(false)
    expect(blob.service.exist?(blob.key)).to be(false)
    expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
  end

  it 'retains the staged locator and refuses a tombstone when storage deletion fails' do
    export, blob = staged_export
    account.update!(deletion_requested_at: 90.days.ago, purge_scheduled_for: 1.minute.ago)
    allow(blob.service).to receive(:delete).with(blob.key).and_raise(Errno::EIO, 'synthetic storage failure')

    expect { Accounts::Purge.call(account) }.to raise_error(Accounts::Purge::StorageFailure)
    expect(account.reload).not_to be_purged
    expect(export.reload.staged_blob.id).to eq(blob.id)
    expect(blob.service.exist?(blob.key)).to be(true)
  end

  it 'does not upload an archive after its export row was purged during the build' do
    export = Accounts::Exports.request!(account, requested_by: admin)
    account.update!(deletion_requested_at: 90.days.ago, purge_scheduled_for: 1.minute.ago)
    job = AccountExportJob.new
    uploaded = nil
    allow(ActiveStorage::Blob).to receive(:create_after_unfurling!).and_wrap_original do |original, **attrs|
      uploaded = original.call(**attrs)
      expect(Accounts::Purge.call(account)).to eq(:purged)
      uploaded
    end

    begin
      job.perform(export.id)
    rescue ActiveRecord::RecordNotFound
      # Inspect storage even when the old finalizer discovers the deleted row.
    end

    expect(uploaded).to be_present
    expect(uploaded.service.exist?(uploaded.key)).to be(false)
    expect(ActiveStorage::Blob.exists?(uploaded.id)).to be(false)
  end

  %i[stage! upload!].each do |boundary|
    it "finishes safely when purge wins after #{boundary}" do
      export = Accounts::Exports.request!(account, requested_by: admin)
      account.update!(deletion_requested_at: 90.days.ago, purge_scheduled_for: 1.minute.ago)
      job = AccountExportJob.new
      uploaded = nil
      allow(job).to receive(boundary).and_wrap_original do |original, row, blob, *rest|
        result = original.call(row, blob, *rest)
        uploaded = blob
        expect(Accounts::Purge.call(account)).to eq(:purged)
        result
      end

      expect { job.perform(export.id) }.not_to raise_error
      expect(uploaded).to be_present
      expect(uploaded.service.exist?(uploaded.key)).to be(false)
      expect(ActiveStorage::Blob.exists?(uploaded.id)).to be(false)
    end
  end

  it 'keeps a failed staged upload discoverable when storage refuses cleanup' do
    export, blob = staged_export
    allow(blob.service).to receive(:delete).with(blob.key).and_raise(Errno::EIO, 'synthetic storage failure')

    AccountExportJob.new.fail_after_retries(export.id, RuntimeError.new('synthetic exhausted retry'))

    expect(export.reload.status).to eq(AccountExport::FAILED)
    expect(export.summary[AccountExport::STAGED_BLOB_ID]).to eq(blob.id)
    expect(blob.service.exist?(blob.key)).to be(true)
  end

  it 'does not replace the previous staged locator when storage refuses cleanup on retry' do
    export, blob = staged_export
    replacement = ActiveStorage::Blob.create_after_unfurling!(io: StringIO.new('next archive'),
                                                            filename: 'next.zip')
    allow(blob.service).to receive(:delete).with(blob.key).and_raise(Errno::EIO, 'synthetic storage failure')

    expect { AccountExportJob.new.send(:stage!, export, replacement) }
      .to raise_error(Accounts::Purge::StorageFailure)
    expect(export.reload.summary[AccountExport::STAGED_BLOB_ID]).to eq(blob.id)
  end

  it 'audits a refused signer visit without retaining its bearer slug' do
    operator = create(:user, :admin, account: create(:account, :operator), platform_operator: true,
                                     otp_secret: User.generate_otp_secret, otp_required_for_login: true)
    template = create(:template, account:, author: admin)
    submission = create(:submission, account:, template:)
    submitter = create(:submitter, account:, submission:, uuid: template.submitters.first['uuid'])
    sign_in(operator)
    post operator_impersonations_path,
         params: { account_id: account.id, user_id: admin.id, reason: 'Security regression support visit',
                   otp_attempt: operator.current_otp }
    expect(response).to have_http_status(:redirect)

    ["/s/#{submitter.slug}", "/s/#{submitter.slug}.json"].each do |path|
      get path, as: :json

      expect(response).to have_http_status(:forbidden)
      event = OperatorEvent.where(action: 'impersonation.refused').last
      expect(event.details['target']).to eq('submit_form#show')
      expect(event.details.to_json).not_to include(submitter.slug)
      expect(event.details['path']).to eq('/s/[FILTERED]')
    end
  end
end
