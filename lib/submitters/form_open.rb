# frozen_string_literal: true

module Submitters
  # Is this signer's form still open to them?
  #
  # The signing page answers this in `SubmitFormController`: the archived /
  # expired / declined pages it renders instead of the form, and the
  # "awaiting" page when an enforced signing order has not reached this person
  # yet. The "View this document as a PDF" door beside the ESIGN consent
  # checkbox has to refuse on exactly the same terms — otherwise a slug that
  # can no longer open the form could still pull the document out of it.
  #
  # So the rule lives here once and both read it. The page asks state by state
  # (it renders a different page for each); the door asks `call`, which is
  # those same predicates and nothing else, so the two cannot drift apart the
  # next time a state is added.
  #
  # 2FA is deliberately not here: that is a question about the person holding
  # the link rather than about the form, and `Submitters::AuthorizedForForm`
  # already answers it for both callers.
  module FormOpen
    module_function

    def call(submitter, form_configs: nil)
      return false if submitter.nil?

      !locked?(submitter) && !awaiting_turn?(submitter, form_configs:)
    end

    def locked?(submitter)
      archived?(submitter) || submitter.submission.expired? || submitter.declined_at?
    end

    # An archived template, submission or account: the document is gone as far
    # as the signer is concerned.
    def archived?(submitter)
      submission = submitter.submission

      submission.template&.archived_at?.present? || submission.archived_at? || submitter.account.archived_at?
    end

    # The "awaiting" page: an enforced signing order that has not reached this
    # signer yet. They cannot open the form, so they cannot open the document.
    # `form_configs` is passed in by the page, which has already loaded them.
    def awaiting_turn?(submitter, form_configs: nil)
      submission = submitter.submission
      form_configs ||= Submitters::FormConfigs.call(submitter, [])

      enforced = form_configs[:enforce_signing_order] ||
                 submission.template&.preferences&.dig('submitters_order') == 'preserved'

      enforced && !Submitters.current_submitter_order?(submitter)
    end
  end
end
