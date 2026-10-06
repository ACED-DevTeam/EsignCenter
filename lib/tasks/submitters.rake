# frozen_string_literal: true

namespace :submitters do
  # The operator's half of migration 20260906090000, which adds the unique
  # index on `submitters (submission_id, uuid)` and refuses to run while any
  # duplicate pair exists. The migration prints the first twenty offenders and
  # then stops the deploy; this prints all of them, with enough to act on.
  #
  # A submitter's uuid is the ROLE it fills on its submission, so two rows
  # sharing one is two people holding one role: one of them has a signing link
  # nobody will ever use, both appear in the audit trail and both are counted.
  # Which of the two to keep is a judgement call about real people — read
  # docs/operations.md, "Duplicate submitter uuids", before deleting anything.
  desc 'List submissions holding two people in one role: rake submitters:duplicate_uuids'
  task duplicate_uuids: :environment do
    rows = ActiveRecord::Base.connection.select_all(<<~SQL.squish).to_a
      SELECT submission_id, uuid, COUNT(*) AS copies
      FROM submitters
      GROUP BY submission_id, uuid
      HAVING COUNT(*) > 1
      ORDER BY submission_id
    SQL

    if rows.empty?
      puts 'No duplicate (submission_id, uuid) pairs. The unique index can be added.'

      next
    end

    puts "#{rows.size} duplicate (submission_id, uuid) pair(s):"

    rows.each do |row|
      submitters = Submitter.where(submission_id: row['submission_id'], uuid: row['uuid']).order(:id)

      puts "  submission ##{row['submission_id']} role #{row['uuid']} — #{row['copies']} submitters:"

      submitters.each do |submitter|
        puts "    ##{submitter.id} #{submitter.email.presence || submitter.phone.presence || '(no address)'} " \
             "sent #{submitter.sent_at || '(never)'} opened #{submitter.opened_at || '(never)'} " \
             "completed #{submitter.completed_at || '(never)'} declined #{submitter.declined_at || '(never)'}"
      end
    end

    puts 'See docs/operations.md, "Duplicate submitter uuids", for how to decide which row stays.'
  end
end
