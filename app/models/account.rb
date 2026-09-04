# frozen_string_literal: true

# == Schema Information
#
# Table name: accounts
#
#  id                              :bigint           not null, primary key
#  account_kind                    :string           default("customer"), not null
#  archived_at                     :datetime
#  deletion_code_attempts          :integer          default(0), not null
#  deletion_code_digest            :string
#  deletion_code_expires_at        :datetime
#  deletion_code_window_started_at :datetime
#  deletion_requested_at           :datetime
#  dormant_warning_for             :datetime
#  dormant_warning_sent_at         :datetime
#  locale                          :string           not null
#  name                            :string           not null
#  purge_scheduled_for             :datetime
#  purge_started_at                :datetime
#  purged_at                       :datetime
#  sending_pause_reason            :string
#  sending_paused_at               :datetime
#  suspended_at                    :datetime
#  suspension_reason               :string
#  timezone                        :string           not null
#  uuid                            :string           not null
#  created_at                      :datetime         not null
#  updated_at                      :datetime         not null
#  deletion_code_user_id           :bigint
#  deletion_requested_by_id        :bigint
#
# Indexes
#
#  index_accounts_on_account_kind              (account_kind)
#  index_accounts_on_deletion_requested_by_id  (deletion_requested_by_id)
#  index_accounts_on_pending_purge             (purge_scheduled_for) WHERE ((purge_scheduled_for IS NOT NULL) AND (purged_at IS NULL))
#  index_accounts_on_suspended_at              (suspended_at) WHERE (suspended_at IS NOT NULL)
#  index_accounts_on_uuid                      (uuid) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (deletion_requested_by_id => users.id) ON DELETE => nullify
#
class Account < ApplicationRecord
  KINDS = [
    OPERATOR_KIND = 'operator',
    INTERNAL_KIND = 'internal',
    CUSTOMER_KIND = 'customer'
  ].freeze

  attribute :uuid, :string, default: -> { SecureRandom.uuid }

  has_one_attached :logo

  has_many :users, dependent: :destroy
  has_many :account_counters, dependent: :delete_all
  has_one :account_subscription, dependent: :destroy
  has_one :limit_override, class_name: 'AccountLimitOverride', dependent: :destroy
  has_many :abuse_flags, dependent: :destroy
  # Seats held for people who have not arrived yet (Session 7 Phase B).
  has_many :account_invites, dependent: :destroy
  has_many :encrypted_configs, dependent: :destroy
  has_many :account_configs, dependent: :destroy
  has_many :email_messages, dependent: :destroy
  has_many :templates, dependent: :destroy
  has_many :template_folders, dependent: :destroy
  has_one :default_template_folder, -> { where(name: TemplateFolder::DEFAULT_NAME) },
          class_name: 'TemplateFolder', dependent: :destroy, inverse_of: :account
  has_many :submissions, dependent: :destroy
  has_many :submitters, dependent: :destroy
  has_many :account_linked_accounts, dependent: :destroy
  has_many :email_events, dependent: :destroy
  has_many :document_metadata, class_name: 'DocumentMetadata', dependent: :destroy
  has_many :webhook_urls, dependent: :destroy
  has_many :webhook_events, dependent: nil
  has_many :account_accesses, dependent: :destroy
  # Rows the app deletes by hand in the purge inventory (lib/accounts/purge.rb)
  # rather than through a cascade. They are declared here anyway, because a
  # foreign key with no association is exactly what makes `account.destroy`
  # blow up with InvalidForeignKey — the Session 1 handoff's provisioning_events
  # bug. `search_entries` and `completed_submitters` are projections that can be
  # rebuilt; `provisioning_events` is a log of how the account was created.
  has_many :provisioning_events, dependent: :delete_all
  has_many :search_entries, dependent: :delete_all
  has_many :completed_submitters, dependent: :delete_all
  # The Stripe audit is NOT the account's to take with it: the inbox rows say
  # what Stripe told us and when, and they outlive the customer (nullified, so
  # the money history stays readable).
  has_many :stripe_event_inboxes, dependent: :nullify
  # Where people came from and where they went. Both sides point at accounts,
  # so both are declared; the purge deletes them outright.
  has_many :account_moves_from, class_name: 'AccountMove', foreign_key: :from_account_id,
                                dependent: :delete_all, inverse_of: :from_account
  has_many :account_moves_to, class_name: 'AccountMove', foreign_key: :to_account_id,
                              dependent: :delete_all, inverse_of: :to_account
  has_many :account_testing_accounts, -> { testing }, dependent: :destroy,
                                                      class_name: 'AccountLinkedAccount',
                                                      inverse_of: :account
  has_one :linked_account_account, dependent: :destroy,
                                   foreign_key: :linked_account_id,
                                   class_name: 'AccountLinkedAccount',
                                   inverse_of: :linked_account
  has_many :linked_account_accounts, dependent: :destroy,
                                     foreign_key: :linked_account_id,
                                     class_name: 'AccountLinkedAccount',
                                     inverse_of: :linked_account
  has_many :linked_accounts, through: :account_linked_accounts
  has_many :testing_accounts, through: :account_testing_accounts, source: :linked_account
  has_many :active_users, -> { active }, dependent: :destroy,
                                         inverse_of: :account, class_name: 'User'

  attribute :timezone, :string, default: 'UTC'
  attribute :locale, :string, default: 'en-US'

  scope :active, -> { where(archived_at: nil) }
  # Accounts whose 90-day deletion window has not yet been purged away.
  scope :pending_deletion, -> { where.not(deletion_requested_at: nil).where(purged_at: nil) }

  validates :account_kind, inclusion: { in: KINDS }

  # Accounts that exist only as another account's testing child. A testing
  # child copies its parent's account_kind (lib/accounts.rb), so the kind alone
  # can never tell the two apart — every operator-scoped lookup subtracts this
  # set.
  def self.testing_child_ids
    AccountLinkedAccount.testing.select(:linked_account_id)
  end

  def operator?
    account_kind == OPERATOR_KIND
  end

  def internal?
    account_kind == INTERNAL_KIND
  end

  def customer?
    account_kind == CUSTOMER_KIND
  end

  def testing?
    linked_account_account&.testing?
  end

  # An admin has asked us to delete the account and the 90 days have not run
  # out yet. The account is suspended (read-only) for the whole window, so
  # everyone can still sign in, read and export what they need.
  def pending_deletion?
    deletion_requested_at.present? && purged_at.blank?
  end

  # Everything this account owned has been destroyed; the row that is left is
  # a tombstone (lib/accounts/purge.rb).
  def purged?
    purged_at.present?
  end

  # A purge has CLAIMED this account and is running, or died part-way and will
  # be resumed (review batch 2, P1). From this moment the account is committed:
  # sign-in stops, and cancelling the deletion is refused — there is no longer
  # anything whole to come back to.
  def purge_claimed?
    purge_started_at.present? || purged_at.present?
  end

  # Configuration belongs to this account first. Testing children may inherit
  # from their testing parent only when the child has no usable value.
  def configuration_lookup_accounts
    link = linked_account_account

    [self, (link.account if link&.testing?)].compact
  end

  def tz_info
    @tz_info ||= TZInfo::Timezone.get(ActiveSupport::TimeZone::MAPPING[timezone] || timezone)
  end

  def default_template_folder
    super || build_default_template_folder(name: TemplateFolder::DEFAULT_NAME,
                                           author_id: users.minimum(:id)).tap(&:save!)
  end
end
