# frozen_string_literal: true

class CreateVerifiedDocuments < ActiveRecord::Migration[8.1]
  # The public /verify answer set. No foreign keys on purpose: a row must
  # outlive the account and the submission it came from (D43).
  def change
    create_table :verified_documents do |t|
      t.string :sha256, null: false
      t.datetime :signed_at, null: false
      t.integer :signers_count, null: false
      t.bigint :account_id
      t.bigint :submission_id
      t.string :kind, null: false

      t.timestamps
    end

    add_index :verified_documents, :sha256, unique: true
  end
end
