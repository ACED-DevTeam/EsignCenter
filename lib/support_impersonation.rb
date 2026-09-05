# frozen_string_literal: true

# Support impersonation: a platform operator looking at a customer's account
# as one of its people, so they can help with what the customer is actually
# seeing.
#
# The whole of this file is the answer to one question — "what is this session
# allowed to do?" — and it is deliberately written as a WHITELIST. A request
# that changes something is refused unless it is named here as a document
# action, the session was started in edit mode, and the action is not one of
# the per-action overrides below — permanent deletion, and anything that
# completes a form for a signer, are refused in edit mode too. Everything else
# is refused, including doors nobody has thought about yet: a controller added
# next month is closed the day it is routed, and the spec below (spec/golden/
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

  # Every controller in the application, and which side of the line it is on.
  # EVERY controller, not only the ones with a write route (review batch 2):
  # `submit_form#show` writes on a GET — it saves default values and attaches
  # the impersonated person's own signature to a live submitter row — and
  # `webhook_hmac#show` prints a signing secret on a GET, so a rule that
  # exempted reads was not a rule at all. An unclassified controller is
  # CLOSED, for every verb, so a controller added next month is shut the day
  # it is routed and the spec fails until somebody has decided about it.
  #
  #   :read      — reading is fine; there is nothing here to write, or its
  #                writes are refused.
  #   :edit      — DOCUMENT work. Writes allowed when the session was started
  #                in "Allow document edits" mode, refused in read-only mode.
  #   :forbidden — writes refused in both modes; the page stays readable.
  #   :secret    — never, in either mode, for ANY verb: the page prints a
  #                credential.
  #   :signing   — never, in either mode, for ANY verb: the signer's own
  #                doors. Their GETs are not reads (see above), and an
  #                operator must never sign, decline, delegate or be invited
  #                as the person. The dashboard preview
  #                (`templates_form_preview`) is what a support session looks
  #                at instead.
  #   :export    — never, in either mode, for ANY verb: bulk extraction of
  #                the customer's data.
  #   :anonymous — a visitor's or a machine's door. Writes refused like
  #                anything else; nothing here belongs to the account.
  CLASSIFICATION = {
    # --- documents: the work an edit-mode session exists to do -------------
    'templates' => :edit,
    'templates_clone' => :edit,
    'templates_clone_and_replace' => :edit,
    'templates_detect_fields' => :edit,
    'templates_folders' => :edit,
    'templates_preferences' => :edit,
    'templates_prefillable_fields' => :edit,
    'templates_recipients' => :edit,
    'templates_restore' => :edit,
    'templates_share_link' => :edit,
    'templates_uploads' => :edit,
    'templates_versions' => :edit,
    'template_documents' => :edit,
    'template_folders' => :edit,
    'submissions' => :edit,
    'submissions_resend_email' => :edit,
    'submissions_unarchive' => :edit,
    'submitters' => :edit,
    'submitters_resubmit' => :edit,
    'submitters_send_email' => :edit,
    # The in-app builder and dashboard call these with the browser session.
    # They are document work like the HTML doors above and are classified the
    # same way; Api::ApiBaseController runs the identical rule.
    'api/templates' => :edit,
    'api/templates_clone' => :edit,
    'api/template_builder_sessions' => :edit,
    'api/submissions' => :edit,
    # ActiveStorage's two upload doors have their own base controller,
    # outside ApplicationController, so this rule never runs for them. Listed
    # as document work because that is what they are: the blob they make is
    # inert until one of the controllers above attaches it, and every one of
    # those IS refused in read-only mode.
    'active_storage/direct_uploads' => :edit,
    'active_storage/disk' => :edit,

    # --- reading: the pages a support session is here to look at ------------
    'dashboard' => :read,
    'submissions_archived' => :read,
    'submissions_dashboard' => :read,
    'submissions_download' => :read,
    'submissions_filters' => :read,
    'submissions_preview' => :read,
    'submissions_preview_download' => :read,
    'submission_events' => :read,
    'submitters_autocomplete' => :read,
    'submitters_download' => :read,
    'templates_archived' => :read,
    'templates_archived_submissions' => :read,
    'templates_code_modal' => :read,
    'templates_dashboard' => :read,
    'templates_form_preview' => :read, # the safe preview, instead of /s/:slug
    'templates_form_preview_document' => :read, # the preview's own PDF (consent View-as-PDF link)
    'templates_preview' => :read,
    'templates_share_link_qr' => :read,
    'template_folders_autocomplete' => :read,
    'preview_document_page' => :read,
    'usage_settings' => :read,
    'api/users' => :read,
    'api/form_events' => :read,
    'api/submission_documents' => :read,
    'api/submission_events' => :read,
    'api/active_storage_blobs_proxy' => :read,
    'active_storage/blobs/proxy' => :read,
    'active_storage/blobs/redirect' => :read,
    'active_storage/representations/proxy' => :read,
    'active_storage/representations/redirect' => :read,

    # --- money --------------------------------------------------------------
    'billing_settings' => :forbidden, # Checkout and the Customer Portal

    # --- the account row, and leaving ---------------------------------------
    'accounts' => :forbidden, # rename, delete, cancel deletion, deletion code

    # --- taking the customer's data out wholesale ----------------------------
    'account_exports' => :export,     # the account archive (Session 8 phase D)
    'submissions_export' => :export,  # every submission of a template as CSV/XLSX

    # --- people, roles, seats, invitations -----------------------------------
    'users' => :forbidden,
    'users_read_only' => :forbidden, # parking and un-parking a seat
    'users_send_reset_password' => :forbidden, # mailing somebody a reset link
    'account_invites' => :forbidden,
    'invites' => :forbidden, # accepting an invitation
    'invitations' => :forbidden, # Devise's set-your-password door

    # --- credentials ---------------------------------------------------------
    'passwords' => :forbidden,     # reset flows
    'profile' => :forbidden,       # name, email address and password
    'mfa_setup' => :forbidden,     # enrolling or removing 2FA
    'api_settings' => :forbidden,  # rotating the API token (page masked)
    'reveal_access_token' => :secret,   # printing the API token
    'mcp_settings' => :secret,          # printing MCP tokens
    'webhook_secret' => :secret,        # the webhook secret header
    'webhook_hmac' => :secret,          # the decrypted HMAC signing secret
    'email_smtp_settings' => :secret,   # the SMTP password
    'testing_api_settings' => :secret,  # the testing account's API token
    'encrypted_user_configs' => :forbidden, # stored signature material
    'user_signatures' => :forbidden,   # their saved signature
    'user_initials' => :forbidden,     # their saved initials
    'user_configs' => :forbidden,      # their own UI preferences

    # --- signing: never, in any mode, for any verb ---------------------------
    # Keyed by the controller's RUNTIME `controller_path`, which is what the
    # rule is handed. Two of these differ from the name in the route table
    # ('..._2fa...' becomes '...2fa...'), and the spec maps one to the other so
    # a future entry cannot be silently ineffective.
    'start_form' => :signing,
    'start_form_email2fa_send' => :signing,
    'submit_form' => :signing,
    'submit_form_decline' => :signing,
    'submit_form_delegate' => :signing,
    'submit_form_invite' => :signing,
    'submit_form_email2fas' => :signing,
    'submit_form_download' => :signing,
    'submit_form_document' => :signing, # the unsigned PDF behind the consent View-as-PDF link
    'submit_form_completed_download' => :signing,
    'submit_form_draw_signature' => :signing,
    'submit_form_metadata' => :signing,
    'submit_form_values' => :signing,
    'send_submission_email' => :signing,
    'api/submitters' => :signing,            # `completed: true` signs for them
    'api/signing_sessions' => :signing,
    'api/submitter_form_views' => :signing,  # stamps opened_at + a view_form event
    'api/submitter_email_clicks' => :signing,
    'api/attachments' => :signing,           # the signer's own file upload

    # --- account configuration -----------------------------------------------
    'account_configs' => :forbidden,
    'account_custom_fields' => :forbidden,
    'notifications_settings' => :forbidden,
    'personalization_settings' => :forbidden,
    'personalization_logo' => :forbidden,
    'esign_settings' => :forbidden,   # signing certificates (operator-only anyway)
    'timestamp_server' => :forbidden, # operator-only anyway
    'search_entries_reindex' => :forbidden, # operator-only anyway
    'webhook_settings' => :forbidden,
    'webhook_events' => :forbidden, # re-delivering pushes data out again
    'webhook_preferences' => :forbidden,
    'template_sharings_testing' => :forbidden, # the testing-share toggle
    'testing_accounts' => :forbidden, # test mode and support sessions never mix

    # The operator's own console is deliberately NOT listed: `console?` keys on
    # the `operator/` path prefix, so a tab added to the console next month is
    # open to a support session's own operator without anybody remembering to
    # add it here.
    #
    # --- not the authenticated app --------------------------------------------
    'sessions' => :anonymous,   # sign in; signing OUT is always allowed
    'registrations' => :anonymous,
    'confirmations' => :anonymous,
    'omniauth_callbacks' => :anonymous,
    'setup' => :anonymous,
    'health' => :anonymous,
    'pwa' => :anonymous,
    'embed_scripts' => :anonymous,
    'turbo/native/navigation' => :anonymous,
    'verify' => :anonymous,     # the public PDF checker
    'marketing' => :anonymous,  # public pricing + trust pages (Session 9)
    'legal' => :anonymous,      # public Terms + Privacy pages (Session 9)
    'reports' => :anonymous,    # the public abuse-report form
    'stripe_webhooks' => :anonymous,
    'postmark_webhooks' => :anonymous,
    'mcp' => :anonymous,        # token-authenticated, no session
    'api/tools' => :anonymous,  # stateless merge/verify
    'api/admin/accounts' => :anonymous, # provisioning, admin-token only
    'embed_template_builder' => :anonymous # token-authenticated
  }.freeze

  # The kinds that mean "never, in either mode, for any verb". Checked BEFORE
  # the read exemption, which is the whole point of them.
  NEVER = %i[secret signing export].freeze

  # Derived, never written twice (review batch 2): the `:secret` value in the
  # table above IS the list, so adding a page to one cannot leave the other
  # behind.
  SECRET_CONTROLLERS = CLASSIFICATION.select { |_, kind| kind == :secret }.keys.freeze

  # Per-ACTION overrides on the `:edit` controllers.
  #
  # The classification answers "is this controller document work?". These
  # answer the question review 8 found nobody was asking — "...and is THIS
  # action on it something a support session may do?". Edit mode was
  # action-blind, so an operator could permanently destroy a customer's signed
  # documents (their submitters and their whole `submission_events` trail with
  # them) and complete a form on a signer's behalf, with no refusal and no
  # audit row.
  #
  # Two rules, and everything else on an `:edit` controller stays allowed:
  #
  #   * nothing a support session does may be IRREVERSIBLE. Archiving is a
  #     soft delete the customer can undo, so it stays; `destroy!` is not, so
  #     it goes. Those doors do both, chosen by `permanently`, which is why
  #     these overrides read the payload rather than only the action name.
  #   * no submitter may transition to COMPLETED. The signer's own doors are
  #     already `:signing` — never, in either mode, for any verb — and these
  #     are the operator-side doors that reach the same place: a creation
  #     payload carrying `completed: true`, and the resubmit door, which opens
  #     a fresh signing session as the person.
  #
  #   :never              — refused in edit mode too, whatever the payload.
  #   :permanent_destroy  — refused when the payload asks for the irreversible
  #                         branch; the archiving branch stays allowed.
  #   :completion         — refused when the payload would mark a submitter
  #                         completed; the same door without it stays allowed.
  EDIT_ACTION_OVERRIDES = {
    'templates#destroy' => :permanent_destroy,
    'submissions#destroy' => :permanent_destroy,
    'api/templates#destroy' => :permanent_destroy,
    'api/submissions#destroy' => :permanent_destroy,
    'submissions#create' => :completion,
    'api/submissions#create' => :completion,
    'submitters_resubmit#update' => :never
  }.freeze

  # What the four destroy doors themselves read (`params[:permanently].in?`).
  # Written the same way on purpose: a value those controllers would treat as
  # "archive" must not be refused here, or support loses the archive button
  # for nothing.
  PERMANENT_VALUES = ['true', true].freeze

  # The keys that sign for somebody, and the ONE question asked about them.
  #
  # The builder does not compare a value against a list of spellings — it asks
  # `attrs[:completed].present?` (lib/submissions/create_from_submitters.rb),
  # so `"false"`, `"no"`, `"0"`, `0`, `"x"` and `2` all mark the submitter
  # finished. A guard that recognised only `true`/`"true"`/`"1"`/`1` was a
  # spelling allow-list in front of a door that accepts anything non-blank,
  # and one character got round it (review 8, V2-1/X1). So the guard asks the
  # builder's own question: refuse when the key is present in the builder's
  # sense — anything but `nil`, `false`, `""` and empty collections.
  #
  # `completed_at` is not read by any creation path today; it is listed so a
  # door that starts reading it is closed the day it does. The other completion
  # routes (`api/submitters#update`, `api/signing_sessions#create`) live on
  # controllers classified `:signing` — never, in either mode, for any verb —
  # and need nothing here.
  COMPLETION_KEYS = %w[completed completed_at].freeze

  # Where the scan may NOT go. `values`, `metadata`, `variables`, `fields` and
  # `preferences` are the CUSTOMER's own data: a checkbox field called
  # "completed" on a compliance template ("Training completed?") is not a
  # request to sign for anybody, and a depth-blind scan refused legitimate
  # support work over it and wrote a refusal into the customer's own audit
  # card (review 8, V2-3/X3). The builder reads `attrs[:completed]` off the
  # submitter node itself and never out of these, so skipping them cannot let
  # a completion through.
  CUSTOMER_DATA_KEYS = %w[values metadata variables fields preferences].freeze

  # What an `impersonation.action` row says actually happened. The row is
  # written AFTER the whole request — the error handling included — because
  # the customer's Support-access card counts ACTIONS THAT LANDED and a 422
  # that changed nothing is not one of them (review 8, X4/W1/Y1/Y3).
  #
  #   * `changed` — the request went through. This is the only outcome the
  #     customer's "Actions" total counts;
  #   * `failed` — the door was open and the request did not go through: the
  #     response says so (4xx, whether the controller rendered it itself or a
  #     `rescue_from` answered it), or it redirected with an alert, which is
  #     how half this application says "no" (review 8, Y3);
  #   * `error` — something raised and nobody answered it. The row still
  #     lands, because "support touched this and it blew up" is exactly what a
  #     customer asking questions a month later needs to see.
  #
  # A request the rule or the ability layer refused gets its
  # `impersonation.refused` row and NO action row: exactly one row per
  # request, whatever happens to it.
  ACTION_CHANGED = 'changed'
  ACTION_FAILED = 'failed'
  ACTION_ERROR = 'error'

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

  # The one rule. Everything is refused unless it is named as allowed, and the
  # order of these lines is the rule:
  #
  #   * the operator's own console is never refused;
  #   * a NEVER kind is refused for every verb — this comes BEFORE the read
  #     exemption, because the doors it covers write on a GET or print a
  #     credential on one (review batch 2);
  #   * an UNCLASSIFIED controller is refused for every verb, so a new one is
  #     closed the day it is routed rather than open until somebody notices;
  #   * reading is otherwise fine;
  #   * of the writes, only signing out and document work in edit mode pass.
  def refuse?(controller_path:, action:, mode:, read_request:, params: {})
    return false if console?(controller_path)

    kind = CLASSIFICATION[controller_path]

    return true if kind.nil? || NEVER.include?(kind)
    return false if read_request
    return false if ALWAYS_ALLOWED.include?("#{controller_path}##{action}")
    return true unless mode == EDIT_MODE && kind == :edit

    edit_action_refused?("#{controller_path}##{action}", params)
  end

  # The per-action half of the rule, asked only of a request edit mode would
  # otherwise allow. An action nobody has listed is allowed, which is safe
  # because its CONTROLLER had to be classified `:edit` to get this far — and
  # the spec sweeps the route table in edit mode too, so an `:edit` controller
  # that grows an action nobody has decided about fails there.
  def edit_action_refused?(target, params)
    case EDIT_ACTION_OVERRIDES[target]
    when :never then true
    when :permanent_destroy then PERMANENT_VALUES.include?(param_value(params, :permanently))
    when :completion then completes_a_submitter?(params)
    else false
    end
  end

  # The payload arrives string-keyed from JSON and symbol-keyed from a test, so
  # both are asked.
  def param_value(params, key)
    return nil unless params.respond_to?(:[])

    value = params[key]
    value.nil? ? params[key.to_s] : value
  end

  # Does this payload ask for a submitter to arrive already signed?
  #
  # Scanned at any depth, because the API accepts submitters as a bare array,
  # under `submission:`, under `submissions:` and through `/init` — all four
  # reach the same builder — but never THROUGH a customer-data key, so only
  # submitter-shaped nodes are ever asked. The question about a completion key
  # is the builder's own: `.present?`.
  def completes_a_submitter?(value)
    case value
    when Hash
      value.any? do |key, nested|
        name = key.to_s

        next false if CUSTOMER_DATA_KEYS.include?(name)
        next true if COMPLETION_KEYS.include?(name) && nested.present?

        completes_a_submitter?(nested)
      end
    when Array then value.any? { |nested| completes_a_submitter?(nested) }
    else false
    end
  end

  def audit_path(request)
    pattern = request.route_uri_pattern

    return "#{request.controller_class.controller_path}##{request.path_parameters[:action]}" if pattern.blank?

    pattern.sub('(.:format)', '').gsub(/[:*]([a-z_]+)/) do
      key = Regexp.last_match(1)

      if %w[slug token signed_uuid signed_key signed_id encoded_key].include?(key)
        '[FILTERED]'
      else
        request.path_parameters[key.to_sym].to_s
      end
    end
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
