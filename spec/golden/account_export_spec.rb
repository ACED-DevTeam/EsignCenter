# frozen_string_literal: true

# Taking your data with you (Session 8 phase D).
#
# The promise this file pins, in one sentence each:
#
#   * an administrator can ask for ONE ZIP holding everything in the account —
#     the uploaded documents, every signed copy, the audit trails, the
#     templates, a CSV of the submissions and a manifest with a checksum for
#     every file — and what comes out is exactly that, no more (the testing
#     sandbox is somebody else's account) and no less;
#   * a file that has gone missing from storage is NAMED rather than fatal;
#   * the door is open to a free account, a suspended one and one that has
#     asked to be deleted, and closed to a viewer, to another tenant and to a
#     support session;
#   * pressing the button twice does not build the zip twice, and five a day
#     is the limit;
#   * the link really does stop working after seven days, and the file really
#     is deleted;
#   * a purge takes the exports with everything else.
#
# Everything is driven through the real doors: HTTP requests for every page,
# a signer's own PUT for the completions, and the job itself for the build.
RSpec.describe 'The account export', type: :request do
  let(:account) { create(:account) }
  let!(:admin) { create(:user, :admin, account:) }

  before { platform_certificate! }

  def act_as(user)
    sign_out(:user)
    reset!
    sign_in(user)
  end

  # The whole flow the page drives, with the build run where the spec can see
  # it rather than wherever Sidekiq happens to be.
  def build_export!(requested_by: admin)
    export = Accounts::Exports.request!(account, requested_by:)

    AccountExportJob.new.perform(export.id) if export.in_progress?

    export.reload
  end

  def with_zip(export, &)
    Tempfile.create(['account-export', '.zip'], binmode: true) do |file|
      file.write(export.archive.download)
      file.flush

      Zip::File.open(file.path, &)
    end
  end

  def zip_paths(export)
    with_zip(export) { |zip| zip.map(&:name) }
  end

  def manifest(export)
    with_zip(export) { |zip| JSON.parse(zip.get_entry('manifest.json').get_input_stream.read) }
  end

  # --- 1. what is in the zip ------------------------------------------------

  describe 'what the zip holds', sidekiq: :inline do
    let!(:template) do
      create(:template, account:, author: admin, only_field_types: %w[text], submitter_count: 2)
    end
    let!(:second_template) do
      create(:template, account:, author: admin, only_field_types: %w[text], attachment_count: 2)
    end

    # A real completed submission: two people, each signing through the
    # signer's own door, so the completed PDFs in the zip are the ones the app
    # really generates.
    let!(:completed) do
      submission = create(:submission, template:, created_by_user: admin)

      template.submitters.each_with_index do |party, index|
        create(:submitter, submission:, account:, uuid: party['uuid'],
                           email: "party-#{index}@example.com", sent_at: Time.current)
      end

      submission.submitters.reload.each { |submitter| complete!(submitter) }

      attach_fixture!(submission.audit_trail, 'audit-trail.pdf')
      attach_fixture!(submission.combined_document, 'combined.pdf')

      submission.reload
    end

    let!(:pending) do
      submission = create(:submission, template: second_template, created_by_user: admin)

      create(:submitter, submission:, account:, uuid: second_template.submitters.first['uuid'],
                         email: 'waiting@example.com', sent_at: Time.current)

      submission.reload
    end

    # The sandbox is a separate account. Its template must not appear.
    let!(:child_template) do
      child_user = Accounts.find_or_create_testing_user(account)

      create(:template, account: child_user.account, author: child_user, only_field_types: %w[text])
    end

    def attach_fixture!(attachment, filename)
      attachment.attach(io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
                        filename:, content_type: 'application/pdf')
    end

    def directory_for(record)
      "templates/#{record.id}-#{Accounts::ExportArchive.slugify(record.name)}"
    end

    it 'holds every template, every signed document, the audit trail, the data and a checksum for each' do
      export = build_export!

      expect(export.status).to eq(AccountExport::READY)
      expect(export.archive).to be_attached

      paths = zip_paths(export)
      book = manifest(export)

      # The deterministic half, named in full.
      fixed = ["#{directory_for(template)}/template.json",
               "#{directory_for(template)}/original/sample-document.pdf",
               "#{directory_for(second_template)}/template.json",
               "#{directory_for(second_template)}/original/sample-document.pdf",
               "#{directory_for(second_template)}/original/sample-document-2.pdf",
               "submissions/#{completed.id}/submission.json",
               "submissions/#{completed.id}/audit-trail.pdf",
               "submissions/#{pending.id}/submission.json",
               'submissions.csv',
               'manifest.json']

      expect(paths).to include(*fixed)

      # And the signed copies, whose filenames the app generates: every one of
      # them is in the completed submission's own folder, and there are as
      # many as the submission really has (each submitter's, plus the combined
      # document).
      generated = paths - fixed
      expected_documents = completed.submitters.sum { |submitter| submitter.documents.count } + 1

      expect(generated).to all(start_with("submissions/#{completed.id}/completed/"))
      expect(generated.size).to eq(expected_documents)

      # The sandbox stays where it is.
      expect(paths.grep(%r{\Atemplates/#{child_template.id}-})).to be_empty
      expect(paths.grep(%r{\Asubmissions/})).to all(match(%r{\Asubmissions/(#{completed.id}|#{pending.id})/}))

      # The manifest describes exactly what is in the file, and every checksum
      # is the checksum of the bytes that are really there.
      expect(book['format_version']).to eq(1)
      expect(book['account']).to eq('id' => account.id, 'name' => account.name)
      expect(book['requested_by']).to eq(admin.email)
      expect(book['missing']).to eq([])
      expect(book['files']).to all(include('path', 'bytes', 'sha256'))
      expect(book['files'].pluck('path')).to match_array(paths - ['manifest.json'])

      with_zip(export) do |zip|
        book['files'].each do |entry|
          bytes = zip.get_entry(entry['path']).get_input_stream.read

          expect(Digest::SHA256.hexdigest(bytes)).to eq(entry['sha256']), "checksum for #{entry['path']}"
          expect(bytes.bytesize).to eq(entry['bytes']), "size for #{entry['path']}"
        end
      end

      expect(book['counts']).to include('templates' => 2, 'template_documents' => 3,
                                        'submissions' => 2, 'audit_trails' => 1,
                                        'completed_documents' => expected_documents)

      # And the summary the page prints says the same thing about the file.
      expect(export.summary['missing']).to eq([])
      expect(export.summary['files']).to eq(book['files'].size)
      expect(export.summary['total_bytes']).to eq(export.archive.blob.byte_size)
    end

    it 'describes each submission and template rather than only shipping the files' do
      export = build_export!

      with_zip(export) do |zip|
        submission = JSON.parse(zip.get_entry("submissions/#{completed.id}/submission.json")
                                   .get_input_stream.read)
        described = JSON.parse(zip.get_entry("#{directory_for(template)}/template.json").get_input_stream.read)

        expect(submission['status']).to eq('completed')
        expect(submission['source']).to eq(completed.source)
        expect(submission['submitters'].pluck('email'))
          .to match_array(completed.submitters.map(&:email))
        expect(submission['submitters'].pluck('status')).to all(eq('completed'))
        expect(submission['submitters'].first['values']).to be_present
        expect(submission['events']).to be_present

        expect(described['name']).to eq(template.name)
        expect(described['fields'].size).to eq(template.fields.size)
        expect(described['submitters'].size).to eq(2)
      end
    end

    it 'names a file that is gone from storage instead of failing the whole export' do
      lost = template.documents.first.blob
      path = "#{directory_for(template)}/original/sample-document.pdf"

      lost.service.delete(lost.key)

      export = build_export!
      book = manifest(export)

      expect(export.status).to eq(AccountExport::READY)
      expect(book['missing']).to eq([{ 'path' => path, 'reason' => 'not_in_storage' }])
      expect(book['files'].pluck('path')).not_to include(path)
      expect(export.summary['missing']).to eq(book['missing'])
      expect(export.summary['missing_count']).to eq(1)
    end

    # Review 2, Opus #9. The object used to be streamed straight into an open
    # zip entry, so one that vanished half-way through left a truncated file
    # in the archive that the manifest did not describe — and the manifest's
    # checksums are the only reason an export can be trusted at all.
    it 'never leaves a file in the zip that the manifest does not describe' do
      lost = template.documents.first.blob
      first = true

      # Gone AFTER the existence check and after the first chunk: the shape
      # that used to open an entry and then abandon it.
      service = ActiveStorage::Blob.service

      allow(service).to receive(:download).and_wrap_original do |original, key, &block|
        if key == lost.key && first
          first = false
          block&.call('partial bytes')

          raise ActiveStorage::FileNotFoundError
        end

        original.call(key, &block)
      end

      export = build_export!
      book = manifest(export)
      paths = zip_paths(export)

      expect(export.status).to eq(AccountExport::READY)
      expect(paths).to match_array(book['files'].pluck('path') + ['manifest.json'])
      expect(book['missing'].pluck('path'))
        .to include("#{directory_for(template)}/original/sample-document.pdf")
    end
  end

  # --- 1b. what a finished submission is OWED (review 2, H7) ----------------

  # Completion is saved before the job that renders the signed copies and the
  # audit trail. Exported in that window — or after that job has failed — the
  # archive used to hold a submission.json saying "completed" with neither
  # artifact beside it and an EMPTY `missing` list: an incomplete archive that
  # looked complete, handed to somebody about to delete the original. Nothing
  # is attached by hand here, which is the whole point of the example.
  describe 'a completed submission whose documents were never generated' do
    let!(:template) { create(:template, account:, author: admin, only_field_types: %w[text]) }

    let!(:submission) do
      record = create(:submission, template:, created_by_user: admin)

      create(:submitter, submission: record, account:, uuid: template.submitters.first['uuid'],
                         email: 'signed@example.com', sent_at: Time.current,
                         completed_at: Time.current)

      record.reload
    end

    it 'says so in the manifest, on the page and in the email instead of exporting in silence' do
      export = build_export!
      book = manifest(export)
      submitter = submission.submitters.first

      expect(export.status).to eq(AccountExport::READY)
      expect(submitter.documents).to be_empty
      expect(submission.audit_trail).not_to be_attached

      expect(book['missing']).to contain_exactly(
        { 'path' => "submissions/#{submission.id}/completed/submitter-#{submitter.id}.pdf",
          'reason' => 'not_generated' },
        { 'path' => "submissions/#{submission.id}/audit-trail.pdf", 'reason' => 'not_generated' }
      )
      expect(export.summary['missing_count']).to eq(2)

      act_as(admin)
      get '/settings/export'

      expect(response.body).to include(I18n.t('account_export_missing_hint', count: 2))
    end

    it 'says nothing about a submission nobody has finished' do
      submission.submitters.first.update!(completed_at: nil)

      expect(manifest(build_export!)['missing']).to eq([])
    end
  end

  # --- 1c. the CSV, written a batch at a time (review 2, #8) ----------------

  # The exporter is still what formats a row; what changed is that the rows
  # are no longer all held at once. The proof that matters is the one thing
  # batching can get wrong: the header row is the UNION of every batch's
  # column names, so a column that only exists in a later batch has to be in
  # the header and every earlier row has to have an empty cell for it.
  describe 'the submissions CSV' do
    let!(:one) { create(:template, account:, author: admin, only_field_types: %w[text]) }
    let!(:two) { create(:template, account:, author: admin, only_field_types: %w[text date]) }

    before do
      stub_const('Accounts::ExportArchive::CSV_BATCH', 1)

      [one, two].each do |template|
        submission = create(:submission, template:, created_by_user: admin)

        create(:submitter, submission:, account:, uuid: template.submitters.first['uuid'],
                           email: "csv-#{template.id}@example.com", sent_at: Time.current)
      end
    end

    it 'writes one header row covering every batch, and a line per submission' do
      export = build_export!
      csv = with_zip(export) { |zip| CSV.parse(zip.get_entry('submissions.csv').get_input_stream.read) }
      book = manifest(export)

      header = csv.first

      expect(csv.size).to eq(3)
      expect(header).to include('Email')
      # The date column exists only on the second template, which is a batch
      # of its own: a header built from the first batch alone would lose it.
      expect(header).to include(*Submissions::GenerateExportFiles.build_headers(
        Submissions::GenerateExportFiles.build_table_rows(Submission.where(account_id: account.id))
      ).to_a)
      expect(csv.drop(1).map(&:size)).to all(eq(header.size))
      expect(csv.drop(1).flatten.compact).to include("csv-#{one.id}@example.com", "csv-#{two.id}@example.com")

      entry = book['files'].find { |file| file['path'] == 'submissions.csv' }

      expect(entry['sha256']).to be_present
      expect(entry['bytes']).to be_positive
    end

    # The memory promise, made measurable: the exporter is never handed more
    # than one batch of submissions at a time. The shape this replaces called
    # it once with every submission in the account and kept the whole
    # formatted row set — and then the CSV String, and then a copy of it — in
    # memory while the PDFs beside it were being streamed a chunk at a time.
    it 'never formats more than one batch of submissions at once' do
      sizes = []

      allow(Submissions::GenerateExportFiles).to receive(:build_table_rows)
        .and_wrap_original do |original, submissions, **options|
          sizes << submissions.count

          original.call(submissions, **options)
        end

      build_export!

      expect(sizes).not_to be_empty
      expect(sizes).to all(be <= Accounts::ExportArchive::CSV_BATCH)
      expect(sizes.sum).to be >= Submission.where(account_id: account.id).count
    end
  end

  # --- 2. the doors ---------------------------------------------------------

  describe 'who may export' do
    before { create(:template, account:, author: admin, only_field_types: %w[text]) }

    it 'lets an administrator ask for one, watch it and download it' do
      act_as(admin)

      get '/settings/export'
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('account_export_none_headline'))

      expect { post '/settings/export' }.to change(AccountExport, :count).by(1)
      expect(response).to redirect_to('/settings/export')

      export = AccountExport.last

      get '/settings/export'
      expect(response.body).to include(I18n.t('account_export_building_headline'))

      AccountExportJob.new.perform(export.id)

      get '/settings/export'
      expect(response.body).to include(I18n.t('account_export_download_button'))

      get "/settings/export/download/#{export.id}"
      expect(response).to have_http_status(:redirect)

      # The signed link really serves the bytes.
      get URI.parse(response.headers['Location']).request_uri
      expect(response).to have_http_status(:ok)
      expect(response.body.bytesize).to eq(export.reload.archive.blob.byte_size)
    end

    it 'refuses a viewer' do
      viewer = create(:user, account:, role: User::VIEWER_ROLE)

      act_as(viewer)

      get '/settings/export'
      expect(response).to redirect_to(root_path)

      expect { post '/settings/export' }.not_to change(AccountExport, :count)
      expect(response).to redirect_to(root_path)
    end

    it 'answers 404 for another account\'s export' do
      export = build_export!
      stranger = create(:user, :admin, account: create(:account))

      act_as(stranger)

      get "/settings/export/download/#{export.id}"
      expect(response).to have_http_status(:not_found)
    end

    # The free plan is the account's own state; a refusal would send the
    # browser to the dashboard, so landing back on the export page is what
    # says the door opened.
    it 'stays open to a free account, a suspended one and one that is being deleted' do
      act_as(admin)

      expect { post '/settings/export' }.to change(AccountExport, :count).by(1)
      expect(response).to redirect_to('/settings/export')

      AccountExport.delete_all
      AccountStates.suspend!(account, reason: 'billing')

      act_as(admin)

      get '/settings/export'
      expect(response).to have_http_status(:ok)
      expect { post '/settings/export' }.to change(AccountExport, :count).by(1)
      expect(response).to redirect_to('/settings/export')

      AccountExport.delete_all
      AccountStates.lift_suspension!(account, reason: 'billing')
      account.update!(deletion_requested_at: Time.current, purge_scheduled_for: 90.days.from_now)
      AccountStates.suspend!(account, reason: Accounts::Deletion::SUSPENSION_REASON)

      act_as(admin)

      get '/settings/export'
      expect(response).to have_http_status(:ok)
      expect { post '/settings/export' }.to change(AccountExport, :count).by(1)
      expect(response).to redirect_to('/settings/export')
    end

    it 'tells the administrator that exporting still works while the account is being deleted' do
      account.update!(deletion_requested_at: Time.current, purge_scheduled_for: 90.days.from_now)
      AccountStates.suspend!(account, reason: Accounts::Deletion::SUSPENSION_REASON)

      act_as(admin)

      get '/settings/export'

      expect(response.body).to include(I18n.t('account_export_pending_deletion_hint'))
    end
  end

  # --- 2b. the download link itself (review 2, H5) --------------------------

  describe 'the download link' do
    def signed_expiry(url)
      _uuid, _purpose, expires_at = ApplicationRecord.signed_id_verifier
                                                     .verified(URI.parse(url).path.split('/')[2])

      expires_at
    end

    it 'is good for ten minutes, not for the life of the file, and is minted fresh on every click' do
      export = build_export!

      act_as(admin)

      get "/settings/export/download/#{export.id}"
      first_url = response.headers['Location']

      expect(signed_expiry(first_url))
        .to be_between(Time.current.to_i, (Accounts::Exports::DOWNLOAD_URL_TTL + 1.minute).from_now.to_i)
      # The file lives for seven days; the LINK must not.
      expect(signed_expiry(first_url)).to be < export.reload.expires_at.to_i

      travel(2.minutes) do
        get "/settings/export/download/#{export.id}"

        expect(response.headers['Location']).not_to eq(first_url)
        expect(signed_expiry(response.headers['Location'])).to be > signed_expiry(first_url)
      end
    end

    it 'is never kept by a shared cache' do
      export = build_export!

      act_as(admin)

      get "/settings/export/download/#{export.id}"
      get URI.parse(response.headers['Location']).request_uri

      expect(response).to have_http_status(:ok)
      expect(response.headers['Cache-Control']).to eq('private, no-store')
      expect(response.headers['Cache-Control']).not_to include('public')
    end

    it 'still lets an ordinary document be cached, so the rule is scoped to the archive' do
      template = create(:template, account:, author: admin, only_field_types: %w[text])
      blob = template.documents.first.blob

      act_as(admin)

      get URI.parse(ActiveStorage::Blob.proxy_url(blob, expires_at: 1.hour.from_now)).request_uri

      expect(response).to have_http_status(:ok)
      expect(response.headers['Cache-Control']).to include('public')
    end
  end

  describe 'a support session' do
    let(:operator_account) { create(:account, :operator) }
    let(:operator) do
      user = create(:user, :admin, account: operator_account, platform_operator: true)
      user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)
      user
    end

    # One example per mode: an authenticator code can only be spent once, so
    # two sessions in one example would meet the console's own replay guard
    # rather than the export door.
    SupportImpersonation::MODES.each do |mode|
      it "may never export the customer's account in #{mode} mode" do
        act_as(operator)

        post operator_impersonations_path,
             params: { account_id: account.id, user_id: admin.id, mode:,
                       reason: 'Ticket 9001 — the customer cannot open their template',
                       otp_attempt: operator.reload.current_otp }

        expect(request.session[SupportImpersonation::SESSION_KEY]).to be_present

        # Refused — by the request-level guard (phase C's classification) or
        # by CanCan a layer deeper, whichever closes first. What must never
        # happen is a page of the customer's export door answering 200.
        get '/settings/export'
        expect(response).not_to have_http_status(:ok)

        expect { post '/settings/export' }.not_to change(AccountExport, :count)
        expect(response).to have_http_status(:forbidden)

        expect(Ability.new(admin, support_impersonation: mode).can?(:export, account)).to be(false)
      end
    end

    it 'is the only thing that closes the door: the same administrator may export normally' do
      expect(Ability.new(admin).can?(:export, account)).to be(true)
    end
  end

  # --- 3. asking twice, and asking too often --------------------------------

  describe 'asking again' do
    it 'hands back the export that is already being built' do
      first = Accounts::Exports.request!(account, requested_by: admin)

      expect { Accounts::Exports.request!(account, requested_by: admin) }
        .not_to change(AccountExport, :count)

      expect(Accounts::Exports.request!(account, requested_by: admin).id).to eq(first.id)
    end

    it 'hands back a ready export that is less than an hour old, and rebuilds an older one' do
      ready = build_export!

      expect { Accounts::Exports.request!(account, requested_by: admin) }
        .not_to change(AccountExport, :count)

      ready.update!(created_at: 61.minutes.ago)

      expect { Accounts::Exports.request!(account, requested_by: admin) }
        .to change(AccountExport, :count).by(1)
    end

    it 'refuses the sixth of the day' do
      Accounts::Exports::MAX_PER_DAY.times do |index|
        export = Accounts::Exports.request!(account, requested_by: admin)

        # Each one has to be finished and aged out of the reuse window, or the
        # next request would simply be handed this one.
        export.update!(status: AccountExport::READY, expires_at: 7.days.from_now,
                       created_at: (index + 2).hours.ago)
      end

      expect { Accounts::Exports.request!(account, requested_by: admin) }
        .to raise_error(Accounts::Exports::LimitReached)

      act_as(admin)
      post '/settings/export'

      expect(flash[:alert]).to eq(I18n.t('account_export_limit_reached',
                                         limit: Accounts::Exports::MAX_PER_DAY))
    end
  end

  # --- 3b. the day's budget, and a build nobody is doing ---------------------

  describe 'a request that never reaches a worker' do
    # Review 2, M8 + Opus #7. The row and the counter commit before the
    # enqueue, so an enqueue that raises used to leave a `pending` row that
    # `reusable` handed to every later request — the export door shut until
    # the sweep noticed two hours later — with one of the day's five spent on
    # a build that never existed.
    it 'is marked failed, gives the day\'s budget back, and says so on the page' do
      allow(AccountExportJob).to receive(:perform_async).and_raise(Redis::CannotConnectError, 'no redis')

      act_as(admin)

      expect { post '/settings/export' }.to change(AccountExport, :count).by(1)

      export = AccountExport.last

      expect(export.status).to eq(AccountExport::FAILED)
      expect(export.error).to include('no redis')
      expect(flash[:alert]).to eq(I18n.t('account_export_enqueue_failed'))
      expect(Accounts::Exports.remaining_today(account)).to eq(Accounts::Exports::MAX_PER_DAY)

      # And the door is open again immediately, rather than being held by a
      # pending row nobody is building.
      allow(AccountExportJob).to receive(:perform_async).and_call_original

      expect { post '/settings/export' }.to change(AccountExport, :count).by(1)
      expect(flash[:notice]).to eq(I18n.t('account_export_started'))
    end

    it 'lets go of a pending row that was never claimed, long before the running fuse' do
      stuck = Accounts::Exports.request!(account, requested_by: admin)

      travel_to((Accounts::Exports::PENDING_STALE_AFTER + 1.minute).from_now) do
        Accounts::Retention.run!

        expect(stuck.reload.status).to eq(AccountExport::FAILED)
        expect(Accounts::Exports.remaining_today(account)).to eq(Accounts::Exports::MAX_PER_DAY)
      end
    end

    it 'gives the budget back when the build itself fails' do
      export = AccountExport.create!(account:, requested_by: admin, status: AccountExport::PENDING)

      AccountCounters.increment!(account.id, Accounts::Exports::COUNTER_KEY,
                                 period: AccountCounters.day_period)

      expect(Accounts::Exports.remaining_today(account)).to eq(Accounts::Exports::MAX_PER_DAY - 1)

      allow(Accounts::ExportArchive).to receive(:call).and_raise(StandardError, 'the bucket said no')

      expect { AccountExportJob.new.perform(export.id) }.to raise_error(StandardError)

      AccountExportJob.new.fail_after_retries(export.id, StandardError.new('the bucket said no'))

      expect(export.reload.status).to eq(AccountExport::FAILED)
      expect(Accounts::Exports.remaining_today(account)).to eq(Accounts::Exports::MAX_PER_DAY)
    end
  end

  # --- 4. the seven days ----------------------------------------------------

  describe 'expiry' do
    it 'deletes the file and closes the door after seven days' do
      export = build_export!
      blob = export.archive.blob

      travel_to(8.days.from_now) do
        Accounts::Retention.run!

        export.reload

        expect(export.status).to eq(AccountExport::EXPIRED)
        expect(export.archive).not_to be_attached
        expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)

        act_as(admin)

        get "/settings/export/download/#{export.id}"

        expect(response).to redirect_to('/settings/export')
        expect(flash[:alert]).to eq(I18n.t('account_export_download_unavailable'))
      end
    end

    it 'lets go of a build whose worker died, so the account is not locked out for ever' do
      stuck = Accounts::Exports.request!(account, requested_by: admin)

      travel_to((Accounts::Exports::STALE_AFTER + 1.hour).from_now) do
        Accounts::Retention.run!

        expect(stuck.reload.status).to eq(AccountExport::FAILED)

        expect { Accounts::Exports.request!(account, requested_by: admin) }
          .to change(AccountExport, :count).by(1)
      end
    end
  end

  # --- 4b. deleting the file the way round that cannot lose it (H6) ---------

  describe 'deleting an expired archive' do
    it 'keeps the row when the object will not delete, and the next sweep finishes the job' do
      export = build_export!
      blob = export.archive.blob
      service = ActiveStorage::Blob.service
      refused = false

      allow(service).to receive(:delete).and_wrap_original do |original, key|
        if key == blob.key && !refused
          refused = true

          raise Errno::EIO, 'the bucket said no'
        end

        original.call(key)
      end

      travel_to(8.days.from_now) do
        Accounts::Retention.run!

        # The file is still there, so the row that names it is still there
        # too: nothing is orphaned, and the download door is shut anyway.
        expect(export.reload.status).to eq(AccountExport::READY)
        expect(export.archive).to be_attached
        expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)
        expect(export.downloadable?).to be(false)

        Accounts::Retention.run!

        expect(export.reload.status).to eq(AccountExport::EXPIRED)
        expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
        expect(service.exist?(blob.key)).to be(false)
      end
    end
  end

  # --- 5. the purge ---------------------------------------------------------

  describe 'the purge', sidekiq: :inline do
    it 'destroys the export rows and their files with everything else' do
      export = build_export!
      blob = export.archive.blob

      account.update!(deletion_requested_at: 90.days.ago, purge_scheduled_for: 1.minute.ago)

      expect(Accounts::Purge.call(account)).to eq(:purged)

      expect(AccountExport.where(account_id: account.id).count).to eq(0)
      expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
      expect(ActiveStorage::Attachment.where(blob_id: blob.id).count).to eq(0)
      expect(Accounts::Purge.remaining_rows([account])['account_exports']).to eq(0)
    end
  end

  # --- 6. the mail ----------------------------------------------------------

  describe 'the email', sidekiq: :inline do
    before { ActionMailer::Base.deliveries.clear }

    it 'tells the person who asked that it is ready, and links to the page rather than the file' do
      export = build_export!

      mail = ActionMailer::Base.deliveries.last

      expect(mail.to).to eq([admin.email])
      expect(mail.subject).to eq('Your EsignCenter account export is ready')
      expect(mail.body.encoded).to include('/settings/export')
      expect(mail.body.encoded).not_to include(export.archive.blob.key)
    end

    # Review 2, M12. The job used to commit READY and then `deliver_later!`
    # outside any rescue: an enqueue that raised took the job down, and the
    # retry's claim then refused the READY row and returned quietly — so the
    # promised email was lost for ever with nothing saying so.
    it 'records that it could not send the message, and the page says so, without rebuilding' do
      allow(AccountMailer).to receive(:export_ready).and_raise(Redis::CannotConnectError, 'no redis')

      export = build_export!

      expect(export.status).to eq(AccountExport::READY)
      expect(export.archive).to be_attached
      expect(export.summary['notified']).to be(false)

      act_as(admin)
      get '/settings/export'

      expect(response.body).to include('data-account-export-not-notified')
      expect(response.body).to include(I18n.t('account_export_not_notified'))
    end

    it 'records the message as sent when it goes out' do
      expect(build_export!.summary['notified']).to be(true)
    end

    it 'tells them when it could not be built' do
      # The row is made directly rather than through the door: this example
      # runs the job inline, so a request would have built the zip before the
      # failure could be arranged.
      export = AccountExport.create!(account:, requested_by: admin, status: AccountExport::PENDING)

      allow(Accounts::ExportArchive).to receive(:call).and_raise(StandardError, 'the bucket said no')

      expect { AccountExportJob.new.perform(export.id) }.to raise_error(StandardError, 'the bucket said no')

      AccountExportJob.new.fail_after_retries(export.id, StandardError.new('the bucket said no'))

      expect(export.reload.status).to eq(AccountExport::FAILED)
      expect(export.error).to include('the bucket said no')

      mail = ActionMailer::Base.deliveries.last

      expect(mail.to).to eq([admin.email])
      expect(mail.subject).to eq('Your EsignCenter account export could not be built')
    end
  end
end
