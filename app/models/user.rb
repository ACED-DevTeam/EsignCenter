# frozen_string_literal: true

# == Schema Information
#
# Table name: users
#
#  id                     :bigint           not null, primary key
#  archived_at            :datetime
#  confirmation_sent_at   :datetime
#  confirmation_token     :string
#  confirmed_at           :datetime
#  consumed_timestep      :integer
#  current_sign_in_at     :datetime
#  current_sign_in_ip     :string
#  email                  :string           not null
#  encrypted_password     :string           not null
#  failed_attempts        :integer          default(0), not null
#  first_name             :string
#  last_name              :string
#  last_sign_in_at        :datetime
#  last_sign_in_ip        :string
#  locked_at              :datetime
#  otp_required_for_login :boolean          default(FALSE), not null
#  otp_secret             :string
#  platform_operator      :boolean          default(FALSE), not null
#  read_only_at           :datetime
#  remember_created_at    :datetime
#  reset_password_sent_at :datetime
#  reset_password_token   :string
#  role                   :string           not null
#  session_version        :integer          default(0), not null
#  sign_in_count          :integer          default(0), not null
#  unconfirmed_email      :string
#  unlock_token           :string
#  uuid                   :string           not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :bigint           not null
#
# Indexes
#
#  index_users_on_account_id            (account_id)
#  index_users_on_email                 (email) UNIQUE
#  index_users_on_read_only_at          (read_only_at) WHERE (read_only_at IS NOT NULL)
#  index_users_on_reset_password_token  (reset_password_token) UNIQUE
#  index_users_on_unlock_token          (unlock_token) UNIQUE
#  index_users_on_uuid                  (uuid) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class User < ApplicationRecord
  ROLES = [
    ADMIN_ROLE = 'admin',
    EDITOR_ROLE = 'editor',
    VIEWER_ROLE = 'viewer'
  ].freeze

  EMAIL_REGEXP = /[^@;,<>\s]+@[^@;,<>\s]+/

  # What separates the password half of the session stamp from the version
  # half (see `authenticatable_salt`). A character bcrypt's alphabet never
  # produces, so no salt can ever collide with a different (salt, version)
  # pair by accident.
  SESSION_VERSION_SEPARATOR = '~'

  FULL_EMAIL_REGEXP =
    /\A[a-z0-9][.']?(?:(?:[a-z0-9_-]+[.+'])*[a-z0-9_-]+)*@(?:[a-z0-9]+[.-])*[a-z0-9]+\.[a-z]{2,}\z/i

  has_one_attached :signature
  has_one_attached :initials

  belongs_to :account
  has_one :access_token, dependent: :destroy
  has_many :access_tokens, dependent: :destroy
  has_many :mcp_tokens, dependent: :destroy
  has_many :templates, dependent: :destroy, foreign_key: :author_id, inverse_of: :author
  has_many :template_folders, dependent: :destroy, foreign_key: :author_id, inverse_of: :author
  has_many :user_configs, dependent: :destroy
  has_many :encrypted_configs, dependent: :destroy, class_name: 'EncryptedUserConfig'
  has_many :email_messages, dependent: :destroy, foreign_key: :author_id, inverse_of: :author

  devise :two_factor_authenticatable, :confirmable, :recoverable, :rememberable, :validatable, :trackable, :lockable,
         :registerable, :omniauthable, omniauth_providers: %i[google_oauth2]

  attribute :role, :string, default: ADMIN_ROLE
  attribute :uuid, :string, default: -> { SecureRandom.uuid }

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :admins, -> { where(role: ADMIN_ROLE) }
  # People who still hold a seat. A read-only member is still a member — they
  # sign in, read, download and export — they simply do not occupy a seat and
  # cannot create or change anything (Session 7 Phase B, D43).
  scope :full_access, -> { where(read_only_at: nil) }
  scope :read_only, -> { where.not(read_only_at: nil) }

  validates :email, format: { with: /\A[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\z/ }
  # Self-serve sign-up only (save with `context: :registration`): a throwaway
  # mailbox cannot own a free account. Invitations and internal provisioning
  # never run this — an admin may invite whoever they like.
  validate :email_must_be_permanent, on: :registration

  # What the session cookie is stamped with, and the only thing this app can
  # change to END somebody's live browser sessions (review 7, D50 D1).
  #
  # Warden serialises a signed-in person as `[id, authenticatable_salt]` — into
  # the session cookie and, through `rememberable_value`, into the remember-me
  # cookie — and re-reads the record and re-compares the salt on EVERY request
  # (Devise::Models::Authenticatable.serialize_from_session). Devise's own salt
  # is the first 29 characters of the bcrypt hash, so it only ever changes when
  # the password does. That left the app with no way at all to sign somebody
  # out of a browser it cannot see: the only lever was changing their password,
  # which is not ours to change.
  #
  # It is a security boundary that made that a real problem. "Join this team"
  # (Accounts::MoveUser) re-parents a person into somebody else's TENANT, and
  # this app resolves the tenant dynamically — `current_account` is
  # `current_user.account`, read fresh on every request. So a session cookie
  # minted while the person was alone in their own account went on working
  # after the move and simply started answering for the TEAM, at whatever role
  # the invitation granted. Every other credential was already thrown away on
  # the move (API tokens, MCP tokens, OAuth grants, remember-me); the live
  # browser session was the one that could not be.
  #
  # Appending `session_version` closes it. Bumping the column inside the move's
  # transaction makes every cookie ever minted for this person compare unequal
  # the moment it commits, and the request that comes in holding one is signed
  # out exactly as if it had never signed in. The accepting browser is the one
  # exception, and it is handled explicitly: InvitesController re-establishes
  # it with `bypass_sign_in` after the move, which mints a cookie carrying the
  # new number.
  #
  # The password half is kept, not replaced: `super` is still the bcrypt slice,
  # so changing a password still invalidates every session the way it always
  # did. This only adds a second reason for the same cookie to stop matching.
  # A blank salt (a record with no password hash, which the not-null column
  # makes impossible in practice) is handed straight back, because Devise's
  # rememberable raises on a nil salt and a suffix would hide that from it.
  def authenticatable_salt
    salt = super

    return salt if salt.blank?

    "#{salt}#{SESSION_VERSION_SEPARATOR}#{session_version}"
  end

  def access_token
    super || build_access_token.tap(&:save!)
  end

  # A purge that has CLAIMED this account (accounts.purge_started_at) is
  # already destroying it, outside any lock the sign-in could wait on (review
  # batch 2, P1). Signing in at that moment would hand somebody a session over
  # data that is disappearing under them — and, worse, would look to them like
  # the deletion had been called off. A sign-in BEFORE the claim is a
  # different thing entirely and is honoured: the job's re-check reads
  # `users.current_sign_in_at` fresh, so it sees it and stands down.
  def active_for_authentication?
    super && !archived_at? && !account.archived_at? && account.purge_started_at.blank?
  end

  def remember_me
    true
  end

  # Platform-operator surfaces (/jobs, the instance-global fulltext toggle)
  # open only for a user flagged by `rake operator:seed` who has also enrolled
  # 2FA. Enrolled means a secret exists, not just the flag: an admin can flip
  # otp_required_for_login on another user without any OTP ever being entered.
  # Never derived from the account kind: a testing child of the operator
  # account inherits that kind without being an operator.
  def operator_access?
    platform_operator? && otp_required_for_login? && otp_secret.present?
  end

  def admin?
    role == ADMIN_ROLE
  end

  # No seat, so no writing: the Ability layer a suspended account uses is
  # applied to this person alone (lib/ability.rb).
  def read_only?
    read_only_at.present?
  end

  def editor?
    role == EDITOR_ROLE
  end

  def viewer?
    role == VIEWER_ROLE
  end

  def self.sign_in_after_reset_password
    if PasswordsController::Current.user.present?
      !PasswordsController::Current.user.otp_required_for_login
    else
      true
    end
  end

  def initials
    [first_name&.first, last_name&.first].compact_blank.join.upcase
  end

  def full_name
    [first_name, last_name].compact_blank.join(' ')
  end

  def friendly_name
    if full_name.present?
      %("#{full_name.delete('"')}" <#{email}>)
    else
      email
    end
  end

  private

  def email_must_be_permanent
    return unless Registrations.disposable_email?(email)

    errors.add(:email, I18n.t('please_use_a_permanent_email_address'))
  end
end
