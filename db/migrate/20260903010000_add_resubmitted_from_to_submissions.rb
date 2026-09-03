# frozen_string_literal: true

# D73 lineage: a corrected resend points at the submission it was copied
# from, so metering can count a LINEAGE's first completion once. Nullify on
# delete — losing the origin must never take the copy with it.
class AddResubmittedFromToSubmissions < ActiveRecord::Migration[8.1]
  def change
    add_column :submissions, :resubmitted_from_id, :bigint, null: true

    add_index :submissions, :resubmitted_from_id, where: 'resubmitted_from_id IS NOT NULL'

    add_foreign_key :submissions, :submissions, column: :resubmitted_from_id, on_delete: :nullify
  end
end
