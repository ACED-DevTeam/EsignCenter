# frozen_string_literal: true

# One party per role, per submission — enforced by the database.
#
# A submitter's `uuid` is the role it fills on its submission (the uuid of the
# entry in `template_submitters`), so two rows sharing a submission and a uuid
# are two people holding the same role: one of them has a signing link nobody
# will ever use, both appear in the audit trail, and both are counted. Until
# now nothing stopped it — the invite door checked "is this uuid already
# here?" in Ruby and inserted, so two invite requests arriving together both
# passed the check and both inserted (SubmitFormInviteController#create).
#
# Reversible: the index is added, and `down` drops it. Nothing is deleted and
# no column changes. The `up` refuses to add the index while duplicates exist
# rather than letting Postgres fail with an opaque message — an operator who
# hits this needs to be told which submissions to look at, because merging two
# people who both hold a role is a judgement call, not a migration. The census
# below prints the first twenty; `rake submitters:duplicate_uuids` prints them
# all, and docs/operations.md describes what to do with them.
#
# Built CONCURRENTLY, outside a transaction. An ordinary `CREATE UNIQUE INDEX`
# takes a SHARE lock on `submitters` for as long as the build takes, which on
# a populated table means every signing write blocks — a signing outage on
# deploy day. `if_not_exists` makes the step re-runnable, which a concurrent
# build needs: a failed one leaves an INVALID index behind, and the operator
# drops it and runs the migration again.
class AddUniqueIndexOnSubmittersSubmissionUuid < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    duplicates = select_rows(<<~SQL.squish)
      SELECT submission_id, uuid, COUNT(*)
      FROM submitters
      GROUP BY submission_id, uuid
      HAVING COUNT(*) > 1
      LIMIT 20
    SQL

    if duplicates.present?
      raise ActiveRecord::IrreversibleMigration,
            'submitters already holds duplicate (submission_id, uuid) pairs; resolve them before adding the ' \
            'unique index. Run `rake submitters:duplicate_uuids` for the full list and see ' \
            "docs/operations.md (\"Duplicate submitter uuids\"). First offenders: #{duplicates.inspect}"
    end

    add_index :submitters, %i[submission_id uuid], unique: true, algorithm: :concurrently, if_not_exists: true,
                                                   name: 'index_submitters_on_submission_id_and_uuid'
  end

  def down
    remove_index :submitters, name: 'index_submitters_on_submission_id_and_uuid',
                              algorithm: :concurrently, if_exists: true
  end
end
