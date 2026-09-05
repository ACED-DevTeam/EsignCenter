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
  # exactly which file it could not find.
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
          added = write_blob!(zip, unique(state, "#{directory}/original/#{filename_for(attachment)}"),
                              attachment.blob, state)

          state[:counts]['template_documents'] += 1 if added
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
                .preload(:template, submitters: { documents_attachments: :blob })
                .order(:id).find_each do |submission|
        directory = "submissions/#{submission.id}"
        state[:counts]['submissions'] += 1

        write_completed_documents!(zip, submission, directory, state)
        write_audit_trail!(zip, submission, directory, state)
        write_json!(zip, "#{directory}/submission.json", submission_json(submission), state)
      end
    end

    # Every signed copy: each submitter's own completed documents, and the
    # single combined PDF when the submission has one.
    def write_completed_documents!(zip, submission, directory, state)
      submission.submitters.sort_by(&:id).each do |submitter|
        submitter.documents.each do |attachment|
          added = write_blob!(zip, unique(state, "#{directory}/completed/#{filename_for(attachment)}"),
                              attachment.blob, state)

          state[:counts]['completed_documents'] += 1 if added
        end
      end

      return unless submission.combined_document.attached?

      added = write_blob!(zip, unique(state, "#{directory}/completed/#{filename_for(submission.combined_document)}"),
                          submission.combined_document.blob, state)

      state[:counts]['completed_documents'] += 1 if added
    end

    def write_audit_trail!(zip, submission, directory, state)
      return unless submission.audit_trail.attached?

      added = write_blob!(zip, "#{directory}/audit-trail.pdf", submission.audit_trail.blob, state)

      state[:counts]['audit_trails'] += 1 if added
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
    # account. Reused rather than rewritten so the columns a customer already
    # knows are the columns they get here.
    def write_submissions_csv!(zip, account, state)
      submissions = Submission.where(account_id: account.id).order(:id)
      csv = Submissions::GenerateExportFiles.call(submissions, format: :csv,
                                                               expires_at: Accounts.link_expires_at(account))

      write_bytes!(zip, 'submissions.csv', csv.to_s, state)
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

    # One stored file, streamed. Returns false when the object is not in
    # storage: the path goes into `missing` and the export carries on.
    def write_blob!(zip, path, blob, state)
      return record_missing(state, path) if blob.nil? || !stored?(blob)

      digest = Digest::SHA256.new
      bytes = 0

      zip.put_next_entry(path)
      blob.download do |chunk|
        digest << chunk
        bytes += chunk.bytesize
        zip.write(chunk)
      end

      state[:entries] << { 'path' => path, 'bytes' => bytes, 'sha256' => digest.hexdigest }
      state[:paths] << path

      true
    rescue ActiveStorage::FileNotFoundError, Errno::ENOENT
      # The object went away between the check above and the read. The entry
      # that was opened stays in the zip holding whatever arrived before the
      # failure; the manifest does not claim it, and the path is named as
      # missing.
      record_missing(state, path)
    end

    def write_json!(zip, path, data, state)
      write_bytes!(zip, path, JSON.pretty_generate(data), state)
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

    def record_missing(state, path)
      state[:missing] << path
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
        'total_bytes' => File.size(path),
        'sha256' => Digest::SHA256.file(path).hexdigest }
    end

    def filename_for(attachment)
      name = attachment.filename.to_s
      base = slugify(File.basename(name, '.*'))
      extension = slugify(File.extname(name).delete_prefix('.'))

      extension.present? ? "#{base}.#{extension}" : base
    end

    def slugify(value)
      cleaned = value.to_s.unicode_normalize(:nfkd).encode('ASCII', invalid: :replace, undef: :replace, replace: '-')
                     .gsub(SAFE, '-').squeeze('-').delete_prefix('-').delete_suffix('-')

      cleaned.presence&.first(MAX_NAME) || 'file'
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
