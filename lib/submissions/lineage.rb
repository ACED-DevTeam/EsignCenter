# frozen_string_literal: true

module Submissions
  # A resubmit lineage (D73): every time a document is corrected and re-sent,
  # the NEW submission records the family it belongs to
  # (`submissions.lineage_root_id`, the id of the document the family started
  # from) as well as the copy it was made from (`resubmitted_from_id`, kept as
  # the audit pointer).
  #
  # Metering counts a family's first completion ONCE. The family, not the
  # ancestry: two corrections of the same unsigned original are siblings and
  # cannot see each other by walking upwards, so the root is stored on every
  # copy and the family is read in one query.
  #
  # The root id deliberately has no foreign key. Permanently deleting the
  # original must not quietly re-open the family for a second completion, so
  # the number survives the row it names.
  module Lineage
    # Fixed first argument of the two-int pg_advisory_xact_lock (see
    # Quotas::LOCK_NAMESPACE) so lineage locks never collide with another
    # feature's advisory locks.
    LOCK_NAMESPACE = 52_002

    # pg_advisory_xact_lock takes two 32-bit keys.
    LOCK_KEY_LIMIT = 2_147_483_647

    module_function

    # The document this family started from — itself, for an original.
    def root_id(submission)
      return nil if submission.nil?

      submission.lineage_root_id || submission.id
    end

    # Every submission in the family: the root and every copy made from it,
    # however many corrections deep.
    def family_ids(submission)
      root = root_id(submission)

      return [] if root.nil?

      ([root] + Submission.where(lineage_root_id: root).ids).uniq
    end

    # What a copy inherits from the document it corrects: the family it joins
    # (the origin's own family, or the origin itself when the origin starts
    # one) and the audit pointer at the copy it was made from.
    def attributes_for_copy(origin_submission)
      return { resubmitted_from_id: nil, lineage_root_id: nil } if origin_submission.nil?

      { resubmitted_from_id: origin_submission.id,
        lineage_root_id: origin_submission.lineage_root_id || origin_submission.id }
    end

    # Has any copy in this family already been counted as a completion?
    def first_completion_exists?(submission)
      ids = family_ids(submission)

      return false if ids.empty?

      CompletedSubmitter.exists?(submission_id: ids, is_first: true)
    end

    # Two sibling copies finishing at the same moment must not each decide
    # they are the family's first. One lock per family, held for the
    # transaction that takes it — so the check and the insert are one step.
    #
    # Always its own savepoint (`requires_new`): the caller retries on a
    # unique-index collision, and a collision inside a transaction it merely
    # joined would poison the caller's transaction and turn that retry into
    # a loop of "current transaction is aborted".
    def with_family_lock(submission, &)
      root = root_id(submission)

      return yield if root.nil?

      ApplicationRecord.transaction(requires_new: true) do
        ApplicationRecord.connection.execute(
          ApplicationRecord.sanitize_sql_array(['SELECT pg_advisory_xact_lock(?, ?)',
                                                LOCK_NAMESPACE, root.to_i % LOCK_KEY_LIMIT])
        )

        yield
      end
    end
  end
end
