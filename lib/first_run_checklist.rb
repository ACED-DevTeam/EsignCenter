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

  # A template we seeded is not a document they chose. `preferences` is a text
  # column holding JSON, so it is cast for the lookup; an empty string is
  # treated as an empty object rather than blowing the cast up.
  NON_STARTER_TEMPLATE_SQL = <<~SQL.squish
    COALESCE(NULLIF(templates.preferences, ''), '{}')::jsonb ->> :key IS DISTINCT FROM 'true'
  SQL

  module_function

  # Whether this person, on this account, is offered the card at all. The
  # dismissal is per person (UserConfig), so two colleagues decide separately.
  def show?(account:, user:, can_create_templates:)
    return false unless can_create_templates
    return false unless account.customer?
    return false if account.created_at < WINDOW.ago
    return false if dismissed?(user)

    steps_for(account).value?(false)
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

  # Step 1. A document of their own — an upload, a template built from
  # scratch, anything that is not one of the four we put there. Sending one of
  # ours counts too: picking a starter template IS choosing a document, and it
  # would be perverse to leave the step unticked for somebody who took the
  # shortcut the starter templates exist to offer.
  def chose_document?(account)
    account.templates.exists?([NON_STARTER_TEMPLATE_SQL, { key: StarterTemplates::STARTER_PREFERENCE_KEY }]) ||
      account.submissions.exists?
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
