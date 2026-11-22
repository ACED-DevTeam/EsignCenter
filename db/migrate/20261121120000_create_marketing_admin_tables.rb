# frozen_string_literal: true

# The four tables behind the private marketing page at /admin
# (docs/marketing-admin.md). None of them belongs to an account and none of
# them holds a person: every row is a number for a day.
class CreateMarketingAdminTables < ActiveRecord::Migration[8.1]
  def change
    # Page views on the public pages, as counters only: one row per day x
    # event x page x source x campaign tag x device type. No timestamps on
    # purpose — the row must not say when its last visitor came.
    create_table :marketing_page_counts do |t| # rubocop:disable Rails/CreateTableWithTimestamps
      t.date :day, null: false
      t.string :event, null: false
      t.string :path, null: false
      t.string :source, null: false
      t.string :campaign, null: false, default: ''
      t.string :device, null: false
      t.integer :count, null: false, default: 0
    end
    add_index :marketing_page_counts, %i[day event path source campaign device],
              unique: true, name: 'index_marketing_page_counts_unique'

    # What each social app said on one America/Chicago day. A later check on
    # the same day replaces the row.
    create_table :marketing_social_snapshots do |t|
      t.date :day, null: false
      t.string :platform, null: false
      t.string :account_name
      t.bigint :followers
      t.bigint :total_views
      t.bigint :total_likes
      t.integer :post_count
      t.string :collected_by, null: false
      t.text :posts
      t.datetime :fetched_at, null: false
      t.timestamps
    end
    add_index :marketing_social_snapshots, %i[platform day], unique: true

    # The outcome of the latest check per app, so one failing app is visible
    # without hiding the others.
    create_table :marketing_social_statuses do |t|
      t.string :platform, null: false
      t.string :state, null: false
      t.string :error
      t.string :triggered_by
      t.datetime :last_attempt_at
      t.datetime :last_success_at
      t.timestamps
    end
    add_index :marketing_social_statuses, :platform, unique: true

    # Outreach totals the Mac automations report: one number per day per kind.
    create_table :marketing_outreach_counts do |t|
      t.date :day, null: false
      t.string :kind, null: false
      t.integer :count, null: false, default: 0
      t.timestamps
    end
    add_index :marketing_outreach_counts, %i[day kind], unique: true
  end
end
