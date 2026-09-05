# frozen_string_literal: true

require 'zip'

module Accounts
  # Everything one account owns, written into a zip (Session 8 phase D).
  #
  # Two rules run through the whole of this file.
  #
  # MEMORY. An account can hold gigabytes of signed PDFs, so nothing is ever
  # held whole: the zip is written straight into a Tempfile through
  # `Zip::OutputStream`, and every stored file is copied into it chunk by
  # chunk with `blob.download { |chunk| }`. The sha256 of each entry is
  # computed from the same chunks as they go past, so the manifest costs no
  # second pass over the bytes.
  #
  # HONESTY. A file that is missing from storage — a bucket object deleted
  # behind the application's back — does NOT fail the export. It is named in
  # the manifest's `missing` list instead, because an export that refuses to
  # produce anything at all is worse for the customer than one that says
  # exactly which file it could not find. `missing` also names the files that
  # were never MADE: a submission that everybody has signed is expected to
  # have a signed copy per person and an audit trail, and when the generation
  # job has not run (or failed) those are reported as `not_generated` rather
  # than passed over in silence (review 2, H7). Every entry carries a reason,
  # so nothing in that list is a guess.
  #
  # AND THE MANIFEST DESCRIBES THE WHOLE ZIP. Every stored file is spooled to
  # a scratch file FIRST and only copied into the archive once it has arrived
  # complete (review 2, #9): opening the zip entry before the read meant an
  # object that vanished mid-download left a truncated entry in the archive
  # that the manifest did not describe, which is exactly the promise the
  # checksums exist to make.
  #
  # Only the account's OWN rows are walked. A testing child is a separate
  # account row (Accounts.find_or_create_testing_user), so scoping every query
  # by `account_id` excludes the sandbox by construction — the same scoping
  # Accounts::Purge's inventory walks, so what is exported here is what would
  # be destroyed there.
  module ExportArchive
    FORMAT_VERSION = 1

    # Names inside a zip are read by every operating system on earth. Anything
    # that is not a plain letter, digit, dot, dash or underscore becomes a
    # dash, and an id is carried alongside every name so two templates called
    # "Contract" cannot collide.
    SAFE = /[^A-Za-z0-9._-]+/
    MAX_NAME = 80

    # How many submissions are formatted into CSV rows at once. Small enough
    # that a batch is nothing beside the documents this job already streams.
    CSV_BATCH = 250

    module_function

    # Writes the zip for `export` into `path` and returns the summary hash
    # (counts, total bytes, sha256 of the zip, missing files).
    def call(export, path)
      account = export.account
      state = { entries: [], missing: [], counts: Hash.new(0), paths: Set.new }

      Zip::OutputStream.open(path) do |zip|
        write_templates!(zip, account, state)
        write_submissions!(zip, account, state)
        write_submissions_csv!(zip, account, state)
        write_manifest!(zip, export, state)
      end

      summarize(path, state)
    end

    # --- templates ---------------------------------------------------------

    def write_templates!(zip, account, state)
      Template.where(account_id: account.id).preload(:folder, documents_attachments: :blob)
              .order(:id).find_each do |template|
        directory = "templates/#{template.id}-#{slugify(template.name)}"
        state[:counts]['templates'] += 1

        template.documents.each do |attachment|
          add_blob!(zip, "#{directory}/original/#{filename_for(attachment)}", attachment.blob, state,
                    'template_documents')
        end

        write_json!(zip, "#{directory}/template.json", template_json(template), state)
      end
    end

    def template_json(template)
      { 'id' => template.id,
        'name' => template.name,
        'slug' => template.slug,
        'folder' => template.folder&.name,
        'archived_at' => template.archived_at&.utc&.iso8601,
        'created_at' => template.created_at&.utc&.iso8601,
        'updated_at' => template.updated_at&.utc&.iso8601,
        'submitters' => template.submitters,
        'fields' => template.fields,
        'schema' => template.schema }
    end

    # --- submissions -------------------------------------------------------

    def write_submissions!(zip, account, state)
      Submission.where(account_id: account.id)
                .preload(:template, documents_attachments: :blob,
                                    submitters: [{ documents_attachments: :blob },
                                                 { attachments_attachments: :blob }])
                .order(:id).find_each do |submission|
        directory = "submissions/#{submission.id}"
        state[:counts]['submissions'] += 1

        write_submission_documents!(zip, submission, directory, state)
        write_completed_documents!(zip, submission, directory, state)
        write_signer_attachments!(zip, submission, directory, state)
        write_audit_trail!(zip, submission, directory, state)
        report_ungenerated!(submission, directory, state)
        write_json!(zip, "#{directory}/submission.json", submission_json(submission), state)
      end
    end

    # The originals the SUBMISSION owns rather than borrows from its template
    # (review 8, D3). A corrected copy carries its own documents
    # (SubmittersResubmitController), and so does a submission built from a
    # one-off upload; nothing else in this archive names them, so an export
    # without them is short exactly the documents whose only other copy the
    # purge is about to destroy.
    def write_submission_documents!(zip, submission, directory, state)
      submission.documents.each do |attachment|
        add_blob!(zip, "#{directory}/original/#{filename_for(attachment)}", attachment.blob, state,
                  'submission_documents')
      end
    end

    # Everything the SIGNERS put in (review 8, D3): the files they attached to
    # a file field, and the signature, initials and stamp images their
    # signature is made of. Filed under the submitter they belong to, because
    # "who uploaded this" is part of what the file means.
    #
    # These are the customer's evidence as much as the signed PDF is, and they
    # are nowhere else in the zip: `submissions.csv` records a file field as a
    # LINK into our storage (Submissions::GenerateExportFiles), which is worth
    # nothing the moment the account is gone.
    def write_signer_attachments!(zip, submission, directory, state)
      submission.submitters.sort_by(&:id).each do |submitter|
        submitter.attachments.each do |attachment|
          path = "#{directory}/attachments/submitter-#{submitter.id}/#{filename_for(attachment)}"

          add_blob!(zip, path, attachment.blob, state, 'submitter_attachments')
        end
      end
    end

    # Every signed copy: each submitter's own completed documents, and the
    # single combined PDF when the submission has one.
    def write_completed_documents!(zip, submission, directory, state)
      submission.submitters.sort_by(&:id).each do |submitter|
        submitter.documents.each do |attachment|
          add_blob!(zip, "#{directory}/completed/#{filename_for(attachment)}", attachment.blob, state,
                    'completed_documents')
        end
      end

      return unless submission.combined_document.attached?

      add_blob!(zip, "#{directory}/completed/#{filename_for(submission.combined_document)}",
                submission.combined_document.blob, state, 'completed_documents')
    end

    # One counted entry. The name is made unique against everything already in
    # the archive (a signer who uploads two files called `contract.pdf` gets a
    # `-2`, never an overwrite), and the count moves only if the blob really
    # went in — `write_blob!` names a file that has gone from storage in
    # `missing` instead, and `missing` is the manifest's whole promise.
    #
    # `write_audit_trail!` below deliberately does NOT come through here: its
    # path is fixed per submission and putting it through `unique` would
    # register it in `state[:paths]`.
    def add_blob!(zip, path, blob, state, count)
      added = write_blob!(zip, unique(state, path), blob, state)

      state[:counts][count] += 1 if added

      added
    end

    def write_audit_trail!(zip, submission, directory, state)
      return unless submission.audit_trail.attached?

      added = write_blob!(zip, "#{directory}/audit-trail.pdf", submission.audit_trail.blob, state)

      state[:counts]['audit_trails'] += 1 if added
    end

    # The files a FINISHED submission is supposed to have and does not
    # (review 2, H7).
    #
    # Completion is saved before the job that makes its artifacts runs
    # (Submitters::SubmitValues, then ProcessSubmitterCompletionJob), so an
    # export taken while that job is queued — or after it has failed — used to
    # produce a `submission.json` saying "completed" with no signed copy and no
    # audit trail beside it, and an EMPTY `missing` list. That is the one
    # outcome this whole feature must not have: an archive that looks complete
    # and is not, handed to somebody about to delete the original.
    #
    # Only a submission everybody has signed is asked the question, and only
    # when the template really has documents to render — a submission of a
    # template with no documents is not owed any.
    def report_ungenerated!(submission, directory, state)
      return unless submission_status(submission) == 'completed'
      return unless documents_expected?(submission)

      submission.submitters.sort_by(&:id).each do |submitter|
        next if submitter.completed_at.blank?
        next if submitter.documents.any?

        record_missing(state, "#{directory}/completed/submitter-#{submitter.id}.pdf", NOT_GENERATED)
      end

      return if submission.audit_trail.attached?

      record_missing(state, "#{directory}/audit-trail.pdf", NOT_GENERATED)
    end

    def documents_expected?(submission)
      (submission.template_schema.presence || submission.template&.schema).present?
    end

    def submission_json(submission)
      { 'id' => submission.id,
        'status' => submission_status(submission),
        'source' => submission.source,
        'template_id' => submission.template_id,
        'template_name' => submission.template&.name,
        'created_at' => submission.created_at&.utc&.iso8601,
        'completed_at' => submission.submitters.filter_map(&:completed_at).max&.utc&.iso8601,
        'archived_at' => submission.archived_at&.utc&.iso8601,
        'submitters' => submission.submitters.sort_by(&:id).map { |submitter| submitter_json(submitter) },
        'events' => events_summary(submission) }
    end

    def submitter_json(submitter)
      { 'id' => submitter.id,
        'name' => submitter.name,
        'email' => submitter.email,
        'phone' => submitter.phone,
        'status' => submitter.status,
        'sent_at' => submitter.sent_at&.utc&.iso8601,
        'opened_at' => submitter.opened_at&.utc&.iso8601,
        'completed_at' => submitter.completed_at&.utc&.iso8601,
        'declined_at' => submitter.declined_at&.utc&.iso8601,
        'values' => submitter.values }
    end

    # A count per event type rather than every row: the events are the
    # audit trail's material and the PDF beside this file is the audit
    # trail itself.
    def events_summary(submission)
      events = SubmissionEvent.where(submission_id: submission.id)
      unless Entitlements.allowed?(submission.account, :delivery_tracking)
        events = events.where.not(event_type: SubmissionEvents::TRACKING_TYPES)
      end

      events.group(:event_type).count
    end

    # The same three-way answer the webhook payload gives
    # (Submitters::SerializeForWebhook), so an exported submission does not
    # describe itself differently from the one that was pushed out.
    def submission_status(submission)
      submitters = submission.submitters

      if submitters.present? && submitters.all?(&:completed_at?)
        'completed'
      elsif submitters.any?(&:declined_at?)
        'declined'
      else
        submission.expired? ? 'expired' : 'pending'
      end
    end

    # --- the flat files ----------------------------------------------------

    # The same CSV the templates page exports, over every submission in the
    # account — formatted by the very same code, and written into the zip a
    # BATCH AT A TIME (review 2, #8).
    #
    # `Submissions::GenerateExportFiles` still decides what a row looks like,
    # so the columns a customer already knows are the columns they get here.
    # What is no longer reused is its "build every row, then join them all
    # into one String" shape: over an account's whole history that held the
    # entire submission set in memory — twice, because the String was then
    # duplicated — while the PDFs beside it were being streamed a chunk at a
    # time. The memory promise in this file's header stopped at the CSV.
    #
    # Two passes, because the header row is the UNION of the column names of
    # every row and it has to be written first: the first pass discovers the
    # names and throws the rows away, the second rebuilds one batch at a time
    # and writes it out. Twice the formatting work for constant memory, which
    # is the right way round for a job that already streams gigabytes.
    def write_submissions_csv!(zip, account, state)
      scope = Submission.where(account_id: account.id)
      expires_at = Accounts.link_expires_at(account)
      headers = csv_headers(scope, expires_at)

      write_stream!(zip, 'submissions.csv', state) do |write|
        write.call(CSVSafe.generate { |csv| csv << headers })

        each_csv_batch(scope, expires_at) do |rows|
          write.call(CSVSafe.generate do |csv|
            rows.each { |row| csv << Submissions::GenerateExportFiles.extract_columns(row, headers) }
          end)
        end
      end
    end

    def csv_headers(scope, expires_at)
      names = Set.new

      each_csv_batch(scope, expires_at) do |rows|
        names += Submissions::GenerateExportFiles.build_headers(rows)
      end

      names.to_a
    end

    def each_csv_batch(scope, expires_at)
      scope.in_batches(of: CSV_BATCH) do |batch|
        yield Submissions::GenerateExportFiles.build_table_rows(batch, expires_at:)
      end

      nil
    end

    def write_manifest!(zip, export, state)
      account = export.account

      manifest = { 'format_version' => FORMAT_VERSION,
                   'generated_at' => Time.current.utc.iso8601,
                   'account' => { 'id' => account.id, 'name' => account.name },
                   'requested_by' => export.requested_by&.email,
                   'counts' => state[:counts].sort.to_h,
                   'files' => state[:entries],
                   'missing' => state[:missing] }

      # The manifest is the last entry and is deliberately NOT listed in its
      # own `files`: a checksum of a file that contains the checksum cannot
      # exist.
      zip.put_next_entry('manifest.json')
      zip.write(JSON.pretty_generate(manifest))
    end

    # --- writing -----------------------------------------------------------

    # One stored file. Returns false when the object is not in storage: the
    # path goes into `missing` and the export carries on.
    #
    # SPOOLED, NOT STREAMED STRAIGHT IN (review 2, #9). The bytes go to a
    # scratch file on disk — chunk by chunk, so memory is still bounded by one
    # chunk — and the zip entry is opened only once the whole object has
    # arrived. An object that disappears half-way through therefore leaves
    # NOTHING in the archive rather than a truncated entry the manifest cannot
    # describe. The cost is one extra disk write per file, bounded by the size
    # of the largest single document; the gain is that "every file in this zip
    # has a checksum in the manifest" is true without an exception.
    def write_blob!(zip, path, blob, state)
      return record_missing(state, path) if blob.nil? || !stored?(blob)

      digest = Digest::SHA256.new
      bytes = 0

      Tempfile.create(['export-entry', File.extname(path)], binmode: true) do |scratch|
        begin
          blob.download do |chunk|
            digest << chunk
            bytes += chunk.bytesize
            scratch.write(chunk)
          end
        rescue ActiveStorage::FileNotFoundError, Errno::ENOENT
          # It went away between the check above and the read. Nothing has
          # been put into the zip, so there is nothing to take back out.
          return record_missing(state, path)
        end

        scratch.flush
        scratch.rewind

        zip.put_next_entry(path)
        IO.copy_stream(scratch, zip)
      end

      state[:entries] << { 'path' => path, 'bytes' => bytes, 'sha256' => digest.hexdigest }
      state[:paths] << path

      true
    end

    def write_json!(zip, path, data, state)
      write_bytes!(zip, path, JSON.pretty_generate(data), state)
    end

    # An entry whose bytes are produced a piece at a time, so a large one never
    # exists as a single String. The digest and the size are accumulated as
    # the pieces go past.
    #
    # Unlike `write_blob!` this opens the entry before the bytes exist, and
    # that is safe here for a reason: the producer is the database, and a
    # failure there raises out of the whole build rather than leaving a
    # finished zip behind — so there is no archive in which this entry could
    # be truncated and undescribed.
    def write_stream!(zip, path, state)
      digest = Digest::SHA256.new
      bytes = 0

      zip.put_next_entry(path)

      yield(lambda { |chunk|
        piece = chunk.to_s.dup.force_encoding(Encoding::BINARY)

        digest << piece
        bytes += piece.bytesize
        zip.write(piece)
      })

      state[:entries] << { 'path' => path, 'bytes' => bytes, 'sha256' => digest.hexdigest }
      state[:paths] << path

      true
    end

    def write_bytes!(zip, path, body, state)
      bytes = body.to_s.dup.force_encoding(Encoding::BINARY)

      zip.put_next_entry(path)
      zip.write(bytes)

      state[:entries] << { 'path' => path, 'bytes' => bytes.bytesize,
                           'sha256' => Digest::SHA256.hexdigest(bytes) }
      state[:paths] << path

      true
    end

    # Why a file is not in the zip. Two answers, and they are different
    # problems: the object is gone from the bucket, or the application never
    # made it in the first place.
    NOT_IN_STORAGE = 'not_in_storage'
    NOT_GENERATED = 'not_generated'

    def record_missing(state, path, reason = NOT_IN_STORAGE)
      state[:missing] << { 'path' => path, 'reason' => reason }
      state[:paths] << path

      false
    end

    # Asked before the entry is opened, so a file that is not there costs an
    # empty entry rather than a failed export. A storage service that raises
    # on the question is treated as "not there" for the same reason.
    def stored?(blob)
      blob.service.exist?(blob.key)
    rescue StandardError
      false
    end

    # --- names -------------------------------------------------------------

    def summarize(path, state)
      { 'counts' => state[:counts].sort.to_h,
        'files' => state[:entries].size,
        'missing' => state[:missing],
        # Read by the page and the ready email, so neither has to know the
        # shape of the list to say "some expected files are not in here".
        'missing_count' => state[:missing].size,
        'total_bytes' => File.size(path),
        'sha256' => Digest::SHA256.file(path).hexdigest }
    end

    def filename_for(attachment)
      name = attachment.filename.to_s
      base = slugify(File.basename(name, '.*'))
      extension = slugify(File.extname(name).delete_prefix('.'))

      extension.present? ? "#{base}.#{extension}" : base
    end

    # BAD BYTES ARE REPLACED, NEVER RAISED (review 8, C4). `unicode_normalize`
    # refuses a string that is not valid UTF-8 and `encode` refuses one that is
    # tagged binary, and the old order asked both of them the question before
    # anything had scrubbed the bytes — so one filename with a Latin-1 é in it
    # took the whole export down with an encoding error the customer could do
    # nothing about. The bytes are read as UTF-8 and scrubbed FIRST now, and
    # only then normalised: no name is worth failing an account's export for.
    #
    # AND THE RESULT IS ALWAYS A NAME. Every character that could make a zip
    # entry escape its folder is already gone — `/` and `\` are not in SAFE, so
    # nothing here can be an absolute path or contain a directory step — but
    # "." and ".." survive the scrub as legal characters and are not names at
    # all: an entry called ".." is a traversal attempt in every extractor on
    # earth. A name made only of dots becomes "file".
    def slugify(value)
      cleaned = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub('-')
                     .unicode_normalize(:nfkd).encode('ASCII', invalid: :replace, undef: :replace, replace: '-')
                     .gsub(SAFE, '-').squeeze('-').delete_prefix('-').delete_suffix('-')

      return 'file' if cleaned.blank? || cleaned.delete('.').empty?

      cleaned.first(MAX_NAME)
    end

    # Two files of one record can genuinely carry the same name — two
    # submitters signing the same template, or a template built from two
    # uploads of one document. The id is already in the directory, so the
    # collision is resolved with a counter rather than by making every name
    # unreadable.
    def unique(state, path)
      return path unless state[:paths].include?(path)

      extension = File.extname(path)
      base = path.delete_suffix(extension)
      index = 2
      index += 1 while state[:paths].include?("#{base}-#{index}#{extension}")

      "#{base}-#{index}#{extension}"
    end
  end
end
