# frozen_string_literal: true

# Support impersonation: a platform operator looking at a customer's account
# as one of its people, so they can help with what the customer is actually
# seeing.
#
# The whole of this file is the answer to one question — "what is this session
# allowed to do?" — and it is deliberately written as a WHITELIST. A request
# that changes something is refused unless it is named here as a document
# action and the session was started in edit mode. Everything else is refused,
# including doors nobody has thought about yet: a controller added next month
# is closed the day it is routed, and the spec below (spec/golden/
# impersonation_spec.rb) fails until somebody has decided which side of the
# line it is on.
#
# This is the request-level half of the enforcement ("braces"). The other half
# is CanCan (lib/ability.rb, `support_impersonation:`), which takes the same
# doors away one layer deeper. Neither is trusted on its own.
module SupportImpersonation
  # The session key the whole feature hangs off. A plain string because the
  # session is serialized as JSON: the hash inside comes back string-keyed,
  # so it is written string-keyed too and every reader can rely on one shape.
  SESSION_KEY = 'support_impersonation'

  # The freshness proof at the start is the operator's live authenticator
  # code. It cannot be re-proven silently on every page, so the session has a
  # hard end instead: an hour, and then it is over wherever the operator is.
  MAX_DURATION = 60.minutes

  READ_ONLY_MODE = 'read_only'
  EDIT_MODE = 'edit'
  MODES = [READ_ONLY_MODE, EDIT_MODE].freeze

  # Longer than the console's own five: "why are you inside a customer's
  # account, as one of their people" deserves a sentence, not a ticket number.
  MINIMUM_REASON_LENGTH = 10

  # The operator's own console. Never refused — it is the surface the session
  # is driven from, it is behind its own 404 gate, and the end door lives in
  # it.
  CONSOLE_PREFIX = 'operator/'

  # Signing out. The one non-console write that is always allowed, because the
  # alternative is a support session that cannot be walked away from.
  ALWAYS_ALLOWED = %w[sessions#destroy].freeze

  # Pages that PRINT a credential. Refused for every verb, GET included, in
  # both modes: an operator helping with a stuck template has no business
  # reading the customer's API key, MCP token, webhook signing secret or SMTP
  # password, and "I only looked" is exactly the access this feature exists to
  # make impossible. The API settings page is deliberately NOT here — it is
  # where the customer's integration lives and the operator often needs to see
  # that one exists — so it stays open with the token masked instead
  # (app/views/api_settings/index.html.erb).
  SECRET_CONTROLLERS = %w[
    reveal_access_token
    mcp_settings
    webhook_secret
    email_smtp_settings
  ].freeze

  # Every controller in the authenticated app that has a route with a verb
  # other than GET, and which side of the line it is on. Written off the route
  # table rather than off memory, and asserted against the route table by the
  # spec, so a new write door has to be classified here before the suite is
  # green again.
  #
  #   :edit      — a DOCUMENT action. Allowed when the session was started in
  #                "Allow document edits" mode; refused in read-only mode.
  #   :forbidden — never, in either mode.
  #   :secret    — never, in either mode, and for GET as well (see above).
  #   :console   — the operator's own console.
  #   :anonymous — a signer's door, a public page, the sign-in machinery or a
  #                machine API. Not a customer administrator acting inside
  #                their account; refused all the same, because the whitelist
  #                names only :edit.
  CLASSIFICATION = {
    # --- documents: the work an edit-mode session exists to do -------------
    'templates' => :edit,                     # fixing a broken template
    'templates_clone' => :edit,               # ditto
    'templates_clone_and_replace' => :edit,   # ditto
    'templates_detect_fields' => :edit,       # ditto
    'templates_folders' => :edit,             # moving a template between folders
    'templates_preferences' => :edit,         # a template's own settings
    'templates_prefillable_fields' => :edit,  # ditto
    'templates_recipients' => :edit,          # ditto
    'templates_restore' => :edit,             # un-archiving a template
    'templates_share_link' => :edit,          # the template's public link
    'templates_uploads' => :edit,             # uploading a document to fix
    'templates_versions' => :edit,            # a new version of a template
    'template_documents' => :edit,            # ditto
    'template_folders' => :edit,              # renaming/removing a folder
    'submissions' => :edit,                   # sending or removing a document
    'submissions_resend_email' => :edit,      # re-sending the invitation
    'submissions_unarchive' => :edit,         # bringing one back
    'submitters' => :edit,                    # correcting a recipient's address
    'submitters_resubmit' => :edit,           # reopening a stuck signer
    'submitters_send_email' => :edit,         # re-sending one invitation
    # ActiveStorage's two doors have their own base controller, outside
    # ApplicationController, so this rule never runs for them. They are listed
    # as document work because that is what they are: the blob they make is
    # inert until one of the controllers above attaches it, and every one of
    # those IS refused in read-only mode.
    'active_storage/direct_uploads' => :edit,
    'active_storage/disk' => :edit,

    # --- money --------------------------------------------------------------
    'billing_settings' => :forbidden, # Checkout and the Customer Portal

    # --- the account row, and leaving ---------------------------------------
    'accounts' => :forbidden, # rename, delete, cancel deletion, deletion code
    'account_exports' => :forbidden, # a zip of every document the customer has

    # --- people, roles, seats, invitations -----------------------------------
    'users' => :forbidden,
    'users_read_only' => :forbidden, # parking and un-parking a seat
    'users_send_reset_password' => :forbidden, # mailing somebody a reset link
    'account_invites' => :forbidden,
    'invites' => :forbidden,                  # accepting an invitation
    'invitations' => :forbidden,              # Devise's set-your-password door

    # --- credentials ---------------------------------------------------------
    'passwords' => :forbidden,          # reset flows
    'profile' => :forbidden,            # name, email address and password
    'mfa_setup' => :forbidden,          # enrolling or removing 2FA
    'api_settings' => :forbidden,       # rotating the API token
    'reveal_access_token' => :secret,   # printing the API token
    'mcp_settings' => :secret,          # printing MCP tokens
    'encrypted_user_configs' => :forbidden, # stored signature material
    'user_signatures' => :forbidden,    # their saved signature
    'user_initials' => :forbidden,      # their saved initials
    'user_configs' => :forbidden,       # their own UI preferences

    # --- signing: never, in any mode ----------------------------------------
    # Keyed by the controller's RUNTIME `controller_path`, which is what the
    # rule is handed. Two of these differ from the name in the route table
    # ('..._2fa...' becomes '...2fa...'), and the spec maps one to the other so
    # a future entry cannot be silently ineffective.
    'start_form' => :forbidden,
    'start_form_email2fa_send' => :forbidden,
    'submit_form' => :forbidden,          # completing a form as the person
    'submit_form_decline' => :forbidden,
    'submit_form_delegate' => :forbidden,
    'submit_form_invite' => :forbidden,   # in-person / self-signing invite
    'submit_form_email2fas' => :forbidden,

    # --- account configuration -----------------------------------------------
    'account_configs' => :forbidden,
    'account_custom_fields' => :forbidden,
    'notifications_settings' => :forbidden,
    'personalization_settings' => :forbidden,
    'personalization_logo' => :forbidden,
    'email_smtp_settings' => :secret,     # the SMTP password lives here
    'esign_settings' => :forbidden,       # signing certificates (operator-only anyway)
    'timestamp_server' => :forbidden,     # operator-only anyway
    'search_entries_reindex' => :forbidden, # operator-only anyway
    'webhook_settings' => :forbidden,
    'webhook_events' => :forbidden,       # re-delivering pushes data out again
    'webhook_preferences' => :forbidden,
    'webhook_secret' => :secret,          # the signing secret
    'template_sharings_testing' => :forbidden, # the testing-share toggle
    'testing_accounts' => :forbidden, # test mode and support sessions never mix

    # The operator's own console is deliberately NOT listed: `console?` keys on
    # the `operator/` path prefix, so a tab added to the console next month is
    # open to a support session's own operator without anybody remembering to
    # add it here.
    #
    # --- not the authenticated app --------------------------------------------
    'sessions' => :anonymous,          # sign in; signing OUT is always allowed
    'registrations' => :anonymous,
    'confirmations' => :anonymous,
    'omniauth_callbacks' => :anonymous,
    'setup' => :anonymous,
    'verify' => :anonymous,            # the public PDF checker
    'reports' => :anonymous,           # the public abuse-report form
    'send_submission_email' => :anonymous, # a signer asking for their own copy
    'stripe_webhooks' => :anonymous,
    'postmark_webhooks' => :anonymous,
    'mcp' => :anonymous, # token-authenticated, no session
    'embed_template_builder' => :anonymous # token-authenticated, no session
  }.freeze

  module_function

  # Who may be viewed as at all. The console's user table asks this to decide
  # whether to draw the door, and Operator::ImpersonationsController asks the
  # same questions again — one at a time, so each refusal can say which one it
  # was — before it opens one. A live person, in a live customer account, who
  # is not the API-only integration login and does not carry platform access
  # themselves.
  def viewable?(account, user)
    account.customer? && !account.purged? && user.archived_at.nil? &&
      user.role != 'integration' && !user.platform_operator?
  end

  # The one rule. Everything is refused unless it is named as allowed.
  def refuse?(controller_path:, action:, mode:, read_request:)
    return false if console?(controller_path)
    return true if SECRET_CONTROLLERS.include?(controller_path)
    return false if read_request
    return false if ALWAYS_ALLOWED.include?("#{controller_path}##{action}")

    !(mode == EDIT_MODE && CLASSIFICATION[controller_path] == :edit)
  end

  def console?(controller_path)
    controller_path.to_s.start_with?(CONSOLE_PREFIX)
  end

  def started_at(state)
    Time.zone.parse(state['started_at'].to_s)
  rescue ArgumentError
    nil
  end

  # A session with an unreadable or missing start time is over: the one thing
  # that must never happen is an impersonation with no end.
  def expired?(state)
    start = started_at(state)

    start.nil? || start <= MAX_DURATION.ago
  end

  def mode_label(mode)
    I18n.t(mode == EDIT_MODE ? 'support_impersonation_mode_edit' : 'support_impersonation_mode_read_only')
  end

  # The customer's own history: the last few times support looked at this
  # account, each paired with the row that says when it ended. Returns pairs
  # of [start event, end event or nil] so the page can print a duration.
  def recent_for(account, limit: 10)
    starts = OperatorEvent.where(account_id: account.id, action: 'impersonation.start')
                          .newest_first.preload(:subject).limit(limit).to_a

    return [] if starts.empty?

    ends = OperatorEvent.where(account_id: account.id, action: 'impersonation.end')
                        .where("details ->> 'start_event_id' IN (?)", starts.map { |event| event.id.to_s })
                        .to_a.index_by { |event| event.details['start_event_id'].to_i }

    starts.map { |event| [event, ends[event.id]] }
  end
end
