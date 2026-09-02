# frozen_string_literal: true

# A capped free account's uploads are refused while its sends and signings
# still work; paid caps scale with seats and never block sending.
#
# Reaching 1 GB honestly in a spec is impractical, so every "full" account
# here is capped with an AccountLimitOverride (the operator's tool) set to a
# few kilobytes — the SAME code path as the plan default: Quotas.limits_for
# returns the override where present and Quotas::Storage reads nothing else.
# What is measured is the real total of the account's blobs, and every
# upload goes through the real controllers.
RSpec.describe 'Storage quota', type: :request do
  let!(:free_account) { create(:account) }
  let!(:paid_account) { create(:account, :paid, seats: 2) }
  let!(:internal_account) { create(:account, :internal) }
  let(:admins) { {} }
  let(:deliveries) { ActionMailer::Base.deliveries }
  let(:json_headers) { { 'CONTENT_TYPE' => 'application/json', 'ACCEPT' => 'application/json' } }
  let(:pdf_path) { Rails.root.join('spec/fixtures/sample-document.pdf') }
  let(:pdf_size) { pdf_path.size }
  let(:warning_subject_prefix) { 'Your EsignCenter storage is almost full' }

  before do
    platform_certificate!
    deliveries.clear
  end

  def admin_for(account)
    admins[account.id] ||= create(:user, account:)
  end

  def token_headers(account)
    { 'x-auth-token': admin_for(account).access_token.token }
  end

  def act_as(account)
    sign_out(:user)
    reset!
    sign_in(admin_for(account))
  end

  def pdf_upload
    Rack::Test::UploadedFile.new(pdf_path, 'application/pdf')
  end

  def text_template_for(account, **attrs)
    create(:template, account:, author: admin_for(account), only_field_types: %w[text], **attrs)
  end

  # The operator's cap, set to what the account holds now plus `room`.
  def cap!(account, room:)
    AccountLimitOverride.create!(account:, storage_bytes: Quotas::Storage.bytes_used(account) + room)
    account.reload
  end

  def used(account)
    Quotas::Storage.bytes_used(account)
  end

  def full_message(account)
    limits = Quotas.limits_for(account)

    I18n.t('storage_limit_reached', used: ActiveSupport::NumberHelper.number_to_human_size(used(account)),
                                    limit: ActiveSupport::NumberHelper.number_to_human_size(limits.storage_bytes))
  end

  def stored_state
    [Template.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count]
  end

  def refusing
    before = stored_state

    yield

    expect(stored_state).to eq(before)
  end

  def send_one(account, template:)
    Submissions.create_from_emails(template:, user: admin_for(account), source: :invite, mark_as_sent: true,
                                   emails: "signer-#{SecureRandom.hex(4)}@example.com").sole
  end

  it 'counts every blob the account owns once: documents, their previews, the logo and a signed PDF',
     sidekiq: :inline do
    act_as(free_account)
    expect(used(free_account)).to eq(0)

    template = text_template_for(free_account)
    previews = ActiveStorage::Attachment.where(record_type: 'ActiveStorage::Attachment',
                                               record_id: template.documents_attachments.select(:id))
    expect(previews).to exist
    expect(used(free_account)).to eq(pdf_size + previews.joins(:blob).sum('active_storage_blobs.byte_size'))

    post "/templates/#{template.id}/documents", params: { files: [pdf_upload] }
    expect(response).to have_http_status(:ok)

    expect(template.documents_attachments.count).to eq(2)
    expect(used(free_account)).to eq(template.documents_attachments.joins(:blob).sum('active_storage_blobs.byte_size') +
                                     previews.joins(:blob).sum('active_storage_blobs.byte_size'))

    post settings_personalization_logo_path,
         params: { logo: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/sample-image.png'), 'image/png') }
    expect(free_account.reload.logo).to be_attached
    expect(used(free_account)).to eq(used(free_account.reload)) # stable
    expect(used(free_account)).to be > pdf_size + free_account.logo.blob.byte_size

    before_completion = used(free_account)
    submitter = send_one(free_account, template:).submitters.first
    complete!(submitter)

    expect(submitter.reload.documents).to be_attached
    expect(used(free_account)).to be > before_completion
    # Another account's files never leak into this account's total.
    expect(used(paid_account)).to eq(0)
  end

  it 'gives a 2-seat paid account 20 GB and refuses the API upload once capped, creating nothing' do
    expect(Quotas.limits_for(paid_account).storage_bytes).to eq(20.gigabytes)
    expect(Quotas.limits_for(free_account).storage_bytes).to eq(1.gigabyte)

    cap!(paid_account, room: pdf_size - 1)

    refusing do
      post '/api/templates', headers: token_headers(paid_account).merge(json_headers),
                             params: { name: 'Capped',
                                       documents: [{ name: 'doc', file: Base64.encode64(pdf_path.read) }] }.to_json
    end

    expect(response).to have_http_status(:unprocessable_content)
    cap_text = ActiveSupport::NumberHelper.number_to_human_size(pdf_size - 1)
    expect(response.parsed_body['error'])
      .to eq(I18n.t('storage_limit_reached', locale: :en, used: '0 Bytes', limit: cap_text))
    expect(response.parsed_body['error']).to start_with('Your storage is full')
  end

  it 'refuses the dashboard upload, the builder add-document and the logo on a capped free account' do
    act_as(free_account)
    template = text_template_for(free_account)
    cap!(free_account, room: pdf_size - 1)
    message = full_message(free_account)

    refusing { post '/templates_upload', params: { files: [pdf_upload] } }

    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(message)

    refusing { post "/templates/#{template.id}/documents", params: { files: [pdf_upload] } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq('error' => message)

    refusing do
      post settings_personalization_logo_path,
           params: { logo: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/sample-image.png'), 'image/png') }
    end

    expect(response).to have_http_status(:redirect)
    expect(flash[:alert]).to eq(message)
    expect(free_account.reload.logo).not_to be_attached

    # Room for exactly this file: the upload that fits is taken.
    AccountLimitOverride.find_by!(account: free_account).update!(storage_bytes: used(free_account) + (pdf_size * 3))

    expect { post "/templates/#{template.id}/documents", params: { files: [pdf_upload] } }
      .to change { template.documents_attachments.count }.by(1)

    expect(response).to have_http_status(:ok)
  end

  it 'lets a full account swap its logo for one of the same size: the old logo is freed, only growth counts' do
    act_as(free_account)
    logo = Rails.root.join('spec/fixtures/sample-image.png')

    post settings_personalization_logo_path, params: { logo: Rack::Test::UploadedFile.new(logo, 'image/png') }

    first_blob = free_account.reload.logo.blob
    cap!(free_account, room: 0)

    expect(Quotas::Storage.bytes_used(free_account)).to eq(Quotas.limits_for(free_account).storage_bytes)

    post settings_personalization_logo_path, params: { logo: Rack::Test::UploadedFile.new(logo, 'image/png') }

    expect(response).to have_http_status(:redirect)
    expect(flash[:alert]).to be_nil
    expect(flash[:notice]).to eq(I18n.t('settings_have_been_saved'))
    expect(free_account.reload.logo).to be_attached
    expect(free_account.logo.blob.id).not_to eq(first_blob.id)
    expect(free_account.logo.blob.byte_size).to eq(first_blob.byte_size)

    # One byte bigger than the freed logo does not fit.
    bigger = Tempfile.new(['logo', '.png']).tap do |file|
      file.binmode
      file.write("#{logo.binread}\0".b)
      file.rewind
    end

    post settings_personalization_logo_path, params: { logo: Rack::Test::UploadedFile.new(bigger.path, 'image/png') }

    expect(response).to have_http_status(:redirect)
    expect(flash[:alert]).to eq(full_message(free_account))
    expect(free_account.reload.logo.blob.byte_size).to eq(first_blob.byte_size)
  end

  it 'still takes a signer upload, still sends and still completes on a full account', sidekiq: :inline do
    template = text_template_for(free_account)
    cap!(free_account, room: 0)
    limit = Quotas.limits_for(free_account).storage_bytes

    submission = send_one(free_account, template:)
    submitter = submission.submitters.first

    expect(submission).to be_persisted
    expect(Quotas.share_link_paused?(free_account)).to be_nil

    sign_out(:user)
    reset!
    post '/api/attachments', params: { submitter_slug: submitter.slug,
                                       file: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/sample-image.png'),
                                                                          'image/png') }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['uuid']).to be_present
    expect(submitter.attachments_attachments.count).to eq(1)
    expect(used(free_account)).to be > limit

    complete!(submitter)

    expect(submitter.completed_at).to be_present
    expect(submitter.reload.documents).to be_attached
    expect(used(free_account)).to be > limit
  end

  it 'emails the admins once per month at 80% of the cap', sidekiq: :inline do
    act_as(free_account)
    template = text_template_for(free_account)
    used_before = used(free_account)

    post "/templates/#{template.id}/documents", params: { files: [pdf_upload] }
    expect(response).to have_http_status(:ok)
    expect(deliveries.count { |m| m.subject.start_with?(warning_subject_prefix) }).to eq(0)

    used_after_one = used(free_account)
    delta = used_after_one - used_before
    # One more upload lands above 80% and inside the cap; before it the
    # account sits below 80%.
    AccountLimitOverride.create!(account: free_account, storage_bytes: used_after_one + delta + (delta / 2))
    expect(used(free_account)).to be < Quotas.limits_for(free_account.reload).storage_bytes * 0.8

    post "/templates/#{template.id}/documents", params: { files: [pdf_upload] }
    expect(response).to have_http_status(:ok)
    expect(used(free_account)).to be >= Quotas.limits_for(free_account).storage_bytes * 0.8

    warnings = deliveries.select { |m| m.subject.start_with?(warning_subject_prefix) }
    expect(warnings.size).to eq(1)
    expect(warnings.sole.to).to eq([admin_for(free_account).email])
    expect(warnings.sole.body.encoded).to include('never affected by storage')

    # A further upload above 80% (a tiny logo) sends nothing more this month.
    tiny = Tempfile.new(['tiny', '.png'])
    tiny.binmode
    tiny.write(Vips::Image.black(1, 1).write_to_buffer('.png'))
    tiny.rewind
    post settings_personalization_logo_path, params: { logo: Rack::Test::UploadedFile.new(tiny.path, 'image/png') }

    expect(free_account.reload.logo).to be_attached
    expect(deliveries.count { |m| m.subject.start_with?(warning_subject_prefix) }).to eq(1)
    expect(AccountCounters.value(free_account.id, Quotas::Storage::WARNING_MAIL_KEY)).to eq(2)
  ensure
    tiny&.close!
  end

  it 'never caps an internal account' do
    act_as(internal_account)
    template = text_template_for(internal_account)

    expect(Quotas::Storage.limit_bytes(internal_account)).to be_nil
    expect(Quotas::Storage.assert_available!(internal_account, 1.terabyte)).to be(true)

    expect { post "/templates/#{template.id}/documents", params: { files: [pdf_upload] } }
      .to change { template.documents_attachments.count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(deliveries.count { |m| m.subject.start_with?(warning_subject_prefix) }).to eq(0)
  end
end
