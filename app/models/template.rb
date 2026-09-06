# frozen_string_literal: true

# == Schema Information
#
# Table name: templates
#
#  id               :bigint           not null, primary key
#  archived_at      :datetime
#  fields           :text             not null
#  name             :string           not null
#  preferences      :text             not null
#  schema           :text             not null
#  shared_link      :boolean          default(FALSE), not null
#  slug             :string           not null
#  source           :text             not null
#  submitters       :text             not null
#  variables_schema :text
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  author_id        :bigint           not null
#  external_id      :string
#  folder_id        :bigint           not null
#
# Indexes
#
#  index_templates_on_account_id                       (account_id)
#  index_templates_on_account_id_and_folder_id_and_id  (account_id,folder_id,id) WHERE (archived_at IS NULL)
#  index_templates_on_account_id_and_id_archived       (account_id,id) WHERE (archived_at IS NOT NULL)
#  index_templates_on_author_id                        (author_id)
#  index_templates_on_external_id                      (external_id)
#  index_templates_on_folder_id                        (folder_id)
#  index_templates_on_slug                             (slug) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (author_id => users.id)
#  fk_rails_...  (folder_id => template_folders.id)
#
class Template < ApplicationRecord
  DEFAULT_SUBMITTER_NAME = 'First Party'

  belongs_to :author, class_name: 'User'
  belongs_to :account
  belongs_to :folder, class_name: 'TemplateFolder'

  has_one :search_entry, as: :record, inverse_of: :record, dependent: :destroy if SearchEntry.table_exists?

  before_validation :maybe_set_default_folder, on: :create
  before_save :forget_starter_pristine_marker

  attribute :preferences, :string, default: -> { {} }
  attribute :fields, :string, default: -> { [] }
  attribute :schema, :string, default: -> { [] }
  attribute :submitters, :string, default: -> { [{ name: I18n.t(:first_party), uuid: SecureRandom.uuid }] }
  attribute :slug, :string, default: -> { SecureRandom.base58(14) }
  attribute :source, :string, default: 'native'

  serialize :preferences, coder: JSON
  serialize :fields, coder: JSON
  serialize :variables_schema, coder: JSON
  serialize :schema, coder: JSON
  serialize :submitters, coder: JSON

  has_many_attached :documents

  has_many :schema_documents, ->(e) { where(uuid: e.schema.pluck('attachment_uuid')) },
           class_name: 'ActiveStorage::Attachment', dependent: :destroy, as: :record, inverse_of: :record

  has_many :submissions, dependent: :destroy

  def documents_ready?
    Templates.documents_ready?(self)
  end
  has_many :template_sharings, dependent: :destroy
  has_many :template_accesses, dependent: :destroy
  has_many :template_versions, dependent: :destroy
  has_many :dynamic_documents, dependent: :destroy
  has_many :dynamic_document_versions, through: :dynamic_documents, source: :versions

  has_many :schema_dynamic_documents, lambda { |e|
    where(uuid: e.schema.select { |item| item['dynamic'] }.pluck('attachment_uuid'))
  }, class_name: 'DynamicDocument', dependent: :destroy, inverse_of: :template

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  def application_key
    external_id
  end

  def folder_name
    folder.full_name
  end

  private

  def maybe_set_default_folder
    self.folder ||= account.default_template_folder
  end

  # A seeded starter carries `starter_pristine` until somebody saves it, and
  # this is the somebody (review 10, A-F2). Whatever the save was — a rename,
  # a moved field, a changed signer — the document is now the account's own
  # work, and the one thing the marker is asked about is whether it may be
  # thrown away as a duplicate when its owner joins a team
  # (Accounts::MoveUser#drop_untouched_starters!). So the answer is "no" from
  # the first save onwards, and nobody has to remember to say so.
  #
  # The seeder's own writes all happen BEFORE it puts the marker on, and it
  # puts it on with `update_columns`, which does not run this.
  def forget_starter_pristine_marker
    return unless preferences.is_a?(Hash)
    return if preferences[StarterTemplates::STARTER_PRISTINE_KEY].blank?

    self.preferences = preferences.except(StarterTemplates::STARTER_PRISTINE_KEY)
  end
end
