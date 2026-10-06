# frozen_string_literal: true

class CreateAbuseFlags < ActiveRecord::Migration[8.1]
  def change
    create_table :abuse_flags do |t|
      t.references :account, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :period, null: false, default: ''
      t.string :subject_type
      t.bigint :subject_id
      t.jsonb :details, null: false, default: {}
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :abuse_flags, %i[account_id kind period], unique: true, where: "period <> ''"
    add_index :abuse_flags, %i[resolved_at created_at]
    add_index :abuse_flags, %i[subject_type subject_id]
  end
end
