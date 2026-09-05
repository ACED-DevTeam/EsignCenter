# frozen_string_literal: true

# One row per legal document a person agreed to when they made their login
# (Session 9 phase A). Two rows are written at every sign-up door — the Terms
# of Service and the Privacy Policy — and they are the answer to "what exactly
# did this person agree to, and when?".
#
# `sha256` is the digest of the rendered text as it stood at that moment, so
# the answer survives a rewrite: the version names the text, the digest proves
# it, and the superseded text itself is kept under config/legal/archive (see
# docs/legal.md). Nothing here is ever updated — a new agreement is a new row.
#
# `account_id` is the account the person was in when they accepted. It is what
# the purge deletes by, and it is deliberately NOT a copy of the user's
# current account: somebody who later joins another team accepted these terms
# as a member of the account named here.
class CreateLegalAcceptances < ActiveRecord::Migration[8.1]
  def change
    create_table :legal_acceptances do |t|
      t.references :user, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.string :document, null: false
      t.string :version, null: false
      t.string :sha256, null: false
      t.datetime :accepted_at, null: false
      # Both are what the request carried, so both can legitimately be blank:
      # a console-created login has no request behind it at all.
      t.string :ip
      t.string :user_agent
      t.string :source, null: false

      t.timestamps
    end

    # "What did this person agree to, and is it current?" — the only question
    # anything asks of this table (LegalDocuments.accepted_current?).
    add_index :legal_acceptances, %i[user_id document]
  end
end
