# frozen_string_literal: true

class Ability
  include CanCan::Ability

  # Roles:
  # - viewer: read-only access to documents + manage own profile/personal settings.
  # - editor: viewer + full document management (templates, submissions, submitters).
  # - admin (and the API-only `integration` role / any legacy role): full access,
  #   including user management, account/integration settings, API tokens and webhooks.
  def initialize(user)
    return if user.blank?

    role_abilities(user)
    apply_read_only_layer(user) if read_only?(user)
    plan_abilities(user)
  end

  private

  # Two different things put a person in read-only, and they take away exactly
  # the same doors (Session 7):
  #   * the ACCOUNT is suspended — a customer whose card kept failing;
  #   * the PERSON lost their seat — a member left behind by a downgrade from
  #     the paid plan to the free one (D43), whose admin has not (yet) chosen
  #     to give the seat back.
  def read_only?(user)
    user.read_only? || AccountStates.read_only?(user.account)
  end

  # A suspended account is frozen for writes and nothing else (Session 7): a
  # customer whose card kept failing keeps every door that lets them read,
  # download, export and pay, and loses every door that creates or changes
  # something. One layer, declared AFTER the role grants so it takes away
  # what a role gave, and BEFORE the plan flags so those still decide which
  # features are visible.
  #
  # Deliberately NOT listed: the personal UserConfig rows, and reading of any
  # kind — every download and export controller authorizes a read. The
  # account row itself is handled below, and differently for the two kinds of
  # person this layer catches.
  def apply_read_only_layer(user)
    # Two shapes of refusal, because CanCan asks a different question for
    # each. A `cannot :create` rule is never even LOOKED AT by
    # `authorize!(:manage, thing)` — the rule's action has to match the one
    # being asked about — so every door that authorizes `:manage` walked
    # straight through the list below: the testing-share toggle, renaming or
    # deleting the account, uploading a logo, and buying a seat. The `:manage`
    # refusals therefore come FIRST, and the reading each role was given is
    # put back immediately after, because `:manage` covers `:read` too and
    # losing that would close the pages a frozen account must keep.
    cannot :manage, [TemplateSharing, AccountInvite, Account]
    can :read, TemplateSharing, template: { account_id: user.account_id }

    # The billing page is the one door that has to stay open — it is where
    # the money problem gets fixed — and the people page has to stay readable,
    # because that is where the admin decides who keeps a seat. Both are handed
    # back as abilities of their own, narrow enough to give without giving
    # everything `:manage, Account` implies (renaming it, deleting it, a logo).
    #
    # ONLY to an administrator who still holds a seat, and this is the whole
    # point of the condition: read-only is not one situation but two. An
    # account frozen for a failed payment puts EVERY member here — its viewers
    # and editors included — and handing them `:billing` would let any of them
    # open the Customer Portal and cancel the company's subscription. A member
    # parked read-only by a downgrade is in the same layer on a perfectly
    # healthy paying account, and they must not reach the money either.
    can(%i[read billing administer], Account, id: user.account_id) if user.admin? && !user.read_only?

    cannot %i[create update destroy], [Template, TemplateFolder, TemplateSharing, Submission, Submitter,
                                       User, EncryptedConfig, AccountConfig, WebhookUrl, AccessToken, McpToken]

    # Re-delivering a webhook pushes this account's data out again, on its
    # order. They are member actions with names of their own, so nothing in
    # the create/update/destroy list ever matched them.
    cannot %i[resend refresh], WebhookUrl

    # The MCP door needs `:manage, :mcp` on top of `:use, :mcp`; taking the
    # first away closes it without touching the plan's feature flags.
    cannot :manage, :mcp

    # Their own profile stays theirs: changing a password or a name is not
    # something a failed payment should stop.
    can :manage, User, id: user.id
  end

  # Available to every signed-in user regardless of role.
  def personal_abilities(user)
    can :manage, User, id: user.id
    can :manage, UserConfig, user_id: user.id
    can :manage, EncryptedUserConfig, user_id: user.id
  end

  def role_abilities(user)
    personal_abilities(user)

    if user.role == User::VIEWER_ROLE
      read_abilities(user)

      return
    end

    document_abilities(user)

    return if user.role == User::EDITOR_ROLE

    admin_abilities(user)
  end

  # Plan-keyed feature abilities, for every role: `can :use, :embed` etc. is
  # granted exactly when the account's plan allows the feature (Entitlements);
  # hidden features are never granted. Declared LAST so the explicit `cannot`
  # outranks any broader grant (an admin's `can :manage, :mcp` would otherwise
  # imply `:use, :mcp`). Views ask `can?(:use, :feature)`; the MCP door
  # requires `:use, :mcp` on top of `:manage, :mcp`.
  def plan_abilities(user)
    allowed = Entitlements.allowed_features(user.account)

    allowed.each { |feature| can :use, feature }
    (Entitlements::FEATURES - allowed).each { |feature| cannot :use, feature }
  end

  # Read-only document access (viewer and above).
  def read_abilities(user)
    can :read, Template, Abilities::TemplateConditions.collection(user) do |template|
      Abilities::TemplateConditions.entity(template, user:, ability: 'read')
    end

    can :read, TemplateFolder, account_id: user.account_id
    can :read, TemplateSharing, template: { account_id: user.account_id }
    can :read, Submission, account_id: user.account_id
    can :read, Submitter, account_id: user.account_id
  end

  # Full document management (editor and above).
  def document_abilities(user)
    can %i[read create update], Template, Abilities::TemplateConditions.collection(user) do |template|
      Abilities::TemplateConditions.entity(template, user:, ability: 'manage')
    end

    can :destroy, Template, account_id: user.account_id
    can :manage, TemplateFolder, account_id: user.account_id
    can :manage, TemplateSharing, template: { account_id: user.account_id }
    can :manage, Submission, account_id: user.account_id
    can :manage, Submitter, account_id: user.account_id
  end

  # Account administration (admin / integration / legacy roles only).
  def admin_abilities(user)
    can :manage, User, account_id: user.account_id
    can :manage, EncryptedConfig, account_id: user.account_id
    can :manage, AccountConfig, account_id: user.account_id
    can :manage, Account, id: user.account_id
    # Paying for the account, and administering its people: two abilities of
    # their own, so the billing page and the users page can be authorized
    # without `:manage` — which is what lets a frozen account still be paid
    # for, and its people page still be read, while everything else about the
    # account row is closed (lib/ability.rb read-only layer).
    can %i[billing administer], Account, id: user.account_id
    can :manage, AccountInvite, account_id: user.account_id
    can :manage, AccessToken, user_id: user.id
    can :manage, McpToken, user_id: user.id
    can :manage, WebhookUrl, account_id: user.account_id

    can :manage, :mcp
  end
end
