# frozen_string_literal: true

module Submissions
  # A resubmit lineage (D73): every time a signed document is corrected and
  # re-sent, the NEW submission records the one it was copied from
  # (`submissions.resubmitted_from_id`). Walking that chain upward gives the
  # whole family of copies of one document.
  #
  # Metering counts a family's first completion ONCE: the second copy to be
  # signed adds nothing, because an ancestor already carries the
  # `completed_submitters.is_first` row. Sends still count per copy — the
  # monthly send cap is what bounds abuse here, not the completion cap.
  #
  # The chain is short by nature (a human correcting a document a handful of
  # times), so it is walked one row per hop with no denormalised root column
  # to go stale. HOP_LIMIT is a cheap stop for a chain that a bug — or a
  # cycle written straight into the column — made unreasonably long.
  module Lineage
    HOP_LIMIT = 50

    module_function

    # The submission's own id plus every ancestor id, oldest last.
    def ids(submission)
      return [] if submission.nil? || submission.id.nil?

      ids = [submission.id]
      current = submission.resubmitted_from_id

      HOP_LIMIT.times do
        break if current.nil? || ids.include?(current)

        ids << current
        current = Submission.where(id: current).pick(:resubmitted_from_id)
      end

      ids
    end

    # The oldest ancestor's id — the submission the family started from.
    def root_id(submission)
      ids(submission).last
    end

    # Has any copy in this family already been counted as a completion?
    def first_completion_exists?(submission)
      lineage_ids = ids(submission)

      return false if lineage_ids.empty?

      CompletedSubmitter.exists?(submission_id: lineage_ids, is_first: true)
    end
  end
end
