# frozen_string_literal: true

# The three-step card a brand-new customer account sees at the top of its
# dashboard (D50): choose a document, add a signer, send it.
#
# Every step's done-state is a live query over the tables the work itself
# writes — there is no progress table, nothing to migrate and nothing that can
# go stale. A person who did the three things in a different order, or through
# the API, or before the card existed, sees three ticks and the card goes
# away by itself.
module FirstRunChecklist
  KEYS = %w[choose signer send].freeze

  # How long a new account is offered the card. Long enough for somebody who
  # signed up on a Friday and came back the following month; short enough that
  # it is not part of the furniture.
  WINDOW = 30.days

  module_function

  # Is this account one the checklist is offered to at all — a customer
  # account, still inside the window?
  #
  # Asked twice: by `for`, which draws the card, and by `supersedes_app_tour?`,
  # which stands the app tour's welcome card down for the accounts this
  # checklist owns. It is ONE predicate because those two must be the same
  # answer — the tour card yielding on a rule of its own is how a dashboard
  # ended up offering a beginner's tour to somebody who had just been walked
  # through the checklist (session 10 staging walk, W2).
  def inside_window?(account)
    account.customer? && account.created_at >= WINDOW.ago
  end

  # The steps to draw for this person on this account, or nil when the card is
  # not offered at all. The steps come BACK rather than being asked for a
  # second time by the partial: deciding and drawing are one question, and the
  # three done-states are three queries.
  #
  # The dismissal is per person (UserConfig), so two colleagues decide
  # separately.
  def for(account:, user:, can_create_templates:)
    return unless can_create_templates
    return unless inside_window?(account)
    return if dismissed?(user)

    steps = steps_for(account)

    steps.value?(false) ? steps : nil
  end

  def show?(account:, user:, can_create_templates:)
    self.for(account:, user:, can_create_templates:).present?
  end

  # Does this checklist OWN the account's onboarding — whether or not there is
  # a card to draw today?
  #
  # The upstream app tour's "Welcome to EsignCenter / Start tour" card makes
  # the same offer as the checklist, and the checklist is the one that ticks
  # itself off from real work. Standing the tour card down only while the
  # checklist was actually ON THE PAGE put it straight back the moment the
  # third step was ticked (session 10 staging walk, W2): the account had just
  # sent its first document, the checklist retired itself, and the dashboard
  # congratulated them by offering a beginner's tour.
  #
  # So the question is about the ACCOUNT and not about today's card: a
  # customer account inside the checklist's window has been offered the
  # checklist, and the tour's welcome card has nothing left to say there. It
  # is only the window — a person joining an established account months later
  # is still welcomed by the tour (the checklist never applied to them). Only
  # that card is affected: the tour itself is untouched and still runs from the
  # template builder and from `?tour=true`.
  def supersedes_app_tour?(account)
    inside_window?(account)
  end

  def dismissed?(user)
    user.user_configs.find_by(key: UserConfig::SHOW_FIRST_RUN_CHECKLIST)&.value == false
  end

  # `{ 'choose' => true, 'signer' => false, 'send' => false }`.
  def steps_for(account)
    {
      'choose' => chose_document?(account),
      'signer' => added_signer?(account),
      'send' => sent_it?(account)
    }
  end

  def done_count(steps)
    steps.count { |_, done| done }
  end

  # Where steps 2 and 3 send this person: the document they are working on.
  #
  # Their OWN newest template first. `order(:id).first` handed back a seeded
  # starter on every self-serve account — `StarterTemplates.seed!` runs at
  # sign-up, so the four starters hold the four lowest ids and a document
  # uploaded afterwards can never be first, which sent somebody who had just
  # uploaded a contract to the Bill of Sale instead (review 10, A-F3). A
  # starter is still a fine destination when it is all the account holds:
  # picking one is the other half of "upload/pick a template".
  #
  # One bounded query: the starter marker is an ORDER BY expression rather
  # than a second SELECT, so non-starters sort ahead of starters (Postgres
  # orders true before false descending) and LIMIT 1 takes the newest of the
  # preferred kind. Nil — an account with no template at all, which is what a
  # failed StarterTemplatesJob leaves — is the caller's to answer.
  def step_target_template(account)
    non_starter = StarterTemplates.not_marked_sql

    account.templates.active.order(Arel.sql("(#{non_starter}) DESC"), id: :desc).first
  end

  # Step 1. A document of their own — an upload, a template built from
  # scratch, anything that is not one of the four we put there. Sending one of
  # ours counts too: picking a starter template IS choosing a document, and it
  # would be perverse to leave the step unticked for somebody who took the
  # shortcut the starter templates exist to offer.
  def chose_document?(account)
    StarterTemplates.not_marked(account.templates).exists? || account.submissions.exists?
  end

  # Step 2. Somebody was actually named on a document.
  def added_signer?(account)
    account.submitters.exists?
  end

  # Step 3. It left the building: mailed to a signer, opened through a share
  # link, or already signed.
  def sent_it?(account)
    account.submitters.where.not(sent_at: nil)
           .or(account.submitters.where.not(completed_at: nil))
           .or(account.submitters.where.not(opened_at: nil))
           .exists?
  end
end
