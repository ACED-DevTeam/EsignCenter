# frozen_string_literal: true

# == Schema Information
#
# Table name: account_invites
#
#  id                    :bigint           not null, primary key
#  accepted_at           :datetime
#  email                 :string           not null
#  expires_at            :datetime         not null
#  payment_pending_until :datetime
#  pending_quantity      :integer
#  released_at           :datetime
#  revoked_at            :datetime
#  role                  :string           not null
#  token_digest          :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :bigint           not null
#  collision_user_id     :bigint
#  invited_by_id         :bigint
#
# Indexes
#
#  index_account_invites_on_account_id             (account_id)
#  index_account_invites_on_collision_user_id      (collision_user_id)
#  index_account_invites_on_email                  (email)
#  index_account_invites_on_expires_at             (expires_at)
#  index_account_invites_on_invited_by_id          (invited_by_id)
#  index_account_invites_on_payment_pending_until  (payment_pending_until) WHERE (payment_pending_until IS NOT NULL)
#  index_account_invites_on_token_digest           (token_digest) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (collision_user_id => users.id) ON DELETE => nullify
#  fk_rails_...  (invited_by_id => users.id) ON DELETE => nullify
#
# The raw token is handed back exactly once, by `generate_token`, and is
# never stored: the column holds its SHA-256 digest, so the accept link works
# and a database dump does not.
class AccountInvite < ApplicationRecord
  # 32 bytes of randomness, urlsafe-encoded. Long enough that guessing is not
  # a strategy, short enough to survive an email client's line wrapping.
  TOKEN_BYTES = 32

  # The same shape User demands of an address. Named so the invite flow can
  # refuse a typo BEFORE it prices or buys a seat for it.
  EMAIL_FORMAT = /\A[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\z/

  belongs_to :account
  belongs_to :invited_by, class_name: 'User', optional: true
  # Who held the invited address when this invitation was WRITTEN, if anybody.
  # It exists so the invitation email can name the account somebody is being
  # asked to leave (D50). It is a hint and nothing else: it authorizes no
  # acceptance and chooses no branch, because a week later the address can be
  # held by somebody else, by nobody, or by a login that has since closed
  # (review B1/B2). Everything that decides asks AccountInvites.verdict_for,
  # which reads the address afresh.
  belongs_to :collision_user, class_name: 'User', optional: true

  # The raw token, readable only on the record that just generated it.
  attr_reader :raw_token

  # `pending` is the scope that means "this invitation is holding a seat": it
  # is what occupancy counts, what the users page lists, and what an accept
  # link has to find. A PARKED purchase (`payment_pending_until` set) is none
  # of those things — Stripe has not applied the seat, nobody has been mailed,
  # and the row exists only so the purchase can be finished later — so it is
  # excluded from both scopes and lives in `payment_pending` instead.
  scope :pending, lambda {
    where(accepted_at: nil, revoked_at: nil, payment_pending_until: nil).where(expires_at: Time.current..)
  }
  scope :expired, lambda {
    where(accepted_at: nil, revoked_at: nil, payment_pending_until: nil).where(expires_at: ...Time.current)
  }
  # A seat purchase Stripe parked and has not yet applied, still waiting for
  # the customer's card step (checkpoint 7, B1). Not settled, not accepted,
  # not cancelled.
  scope :payment_pending, lambda {
    where(accepted_at: nil, revoked_at: nil, released_at: nil).where.not(payment_pending_until: nil)
  }

  validates :email, presence: true, format: { with: EMAIL_FORMAT }
  validates :role, inclusion: { in: User::ROLES }
  validates :token_digest, presence: true
  validates :expires_at, presence: true

  before_validation :normalize_email

  class << self
    def digest(raw_token)
      Digest::SHA256.hexdigest(raw_token.to_s)
    end

    # The one way an accept link is resolved. A blank token never matches a
    # row, however many rows there are.
    def find_by_token(raw_token)
      return nil if raw_token.blank?

      find_by(token_digest: digest(raw_token))
    end
  end

  # Mints the token and stores only its digest. Called once, before save; the
  # raw value goes into the email and is then unrecoverable.
  def generate_token
    @raw_token = SecureRandom.urlsafe_base64(TOKEN_BYTES)

    self.token_digest = self.class.digest(@raw_token)

    @raw_token
  end

  def pending?
    payment_pending_until.nil? && accepted_at.nil? && revoked_at.nil? &&
      expires_at.present? && expires_at > Time.current
  end

  def expired?
    payment_pending_until.nil? && accepted_at.nil? && revoked_at.nil? &&
      expires_at.present? && expires_at <= Time.current
  end

  # A parked seat purchase that is still worth finishing: Stripe's own pending
  # update has not expired, and nobody has cancelled, accepted or settled it.
  def payment_pending?
    payment_pending_until.present? && payment_pending_until > Time.current &&
      accepted_at.nil? && revoked_at.nil? && released_at.nil?
  end

  # A hint about how this invitation was WRITTEN, for the mail copy — named so
  # that nobody can mistake it for "this invitation is a move" (review B1/B2).
  # The live answer is AccountInvites.verdict_for.
  def collision_hinted?
    collision_user_id.present?
  end

  private

  def normalize_email
    self.email = email.to_s.strip.downcase
  end
end
