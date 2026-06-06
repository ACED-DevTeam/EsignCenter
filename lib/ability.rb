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

    personal_abilities(user)

    if user.role == User::VIEWER_ROLE
      read_abilities(user)

      return
    end

    document_abilities(user)

    return if user.role == User::EDITOR_ROLE

    admin_abilities(user)
  end

  private

  # Available to every signed-in user regardless of role.
  def personal_abilities(user)
    can :manage, User, id: user.id
    can :manage, UserConfig, user_id: user.id
    can :manage, EncryptedUserConfig, user_id: user.id
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
    can :manage, AccessToken, user_id: user.id
    can :manage, McpToken, user_id: user.id
    can :manage, WebhookUrl, account_id: user.account_id

    can :manage, :mcp
  end
end
