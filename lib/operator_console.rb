# frozen_string_literal: true

# What the operator console needs that no single-account page ever needed: the
# same numbers Quotas answers for ONE account, answered for a whole page of
# them without asking the database once per row.
#
# Nothing here decides anything. Every number is the number Quotas would give
# — the helpers below are grouped forms of Quotas' own queries, and
# spec/golden/operator_console_spec.rb pins each one against the single-account
# function it batches, so the two can never drift apart quietly.
#
module OperatorConsole
  # Everything a row (or the header of an account page) shows about usage.
  Usage = Struct.new(:completions, :sends, :in_flight, :storage_bytes, :seats_used, :limits)

  # How many accounts the "storage over cap" filter will weigh in one go. The
  # chip is the only filter that cannot be asked of the accounts table — it
  # needs every blob every account owns — so it is answered over a bounded
  # slice of the matching accounts and the page says so when it had to stop.
  STORAGE_SCAN_LIMIT = 500

  module_function

  # accounts → { account_id => Usage }. Seven queries plus one per account for
  # storage, whatever the page size.
  def usage_for(accounts)
    accounts = Array.wrap(accounts)

    return {} if accounts.empty?

    billing_by_account = accounts.index_with { |account| Plans.billing_account(account) }
    billings = billing_by_account.values.uniq(&:id)
    families = family_ids(billings)
    seat_families = seat_family_ids(billings)

    completions = completions_by_billing(billings, families)
    sends = sends_by_billing(billings, families)
    open_documents = in_flight_by_billing(families)
    seats = seats_by_billing(seat_families)
    storage = storage_by_billing(families)

    accounts.to_h do |account|
      billing = billing_by_account[account]

      [account.id, Usage.new(completions.fetch(billing.id, 0), sends.fetch(billing.id, 0),
                             open_documents.fetch(billing.id, 0), storage.fetch(billing.id, 0),
                             seats.fetch(billing.id, 0), Quotas.limits_for(billing))]
    end
  end

  # billing id → the ids whose usage rolls up to it (Quotas.account_ids, for
  # many accounts at once).
  def family_ids(billings)
    ids = billings.map(&:id)
    links = AccountLinkedAccount.where(account_id: ids).pluck(:account_id, :linked_account_id)

    ids.index_with { |id| [id] }.tap do |families|
      links.each { |account_id, linked_id| families[account_id] << linked_id }
    end
  end

  # billing id → the ids whose PEOPLE share its seats (Accounts.seat_account_ids,
  # for many accounts at once): itself plus every non-testing linked child that
  # has not been archived.
  def seat_family_ids(billings)
    ids = billings.map(&:id)
    links = AccountLinkedAccount.where(account_id: ids).where.not(account_type: :testing)
                                .pluck(:account_id, :linked_account_id)
    archived = Account.where(id: links.map(&:last)).where.not(archived_at: nil).ids.to_set

    ids.index_with { |id| [id] }.tap do |families|
      links.each { |account_id, linked_id| families[account_id] << linked_id unless archived.include?(linked_id) }
    end
  end

  # Documents completed this month, per billing account (Quotas.completions_this_month).
  #
  # The window is not the same for every account: a free account whose paid
  # plan ended part-way through this month counts from the downgrade, not from
  # the 1st (D43, prospective counters). So the page's accounts are grouped by
  # the instant their month starts — in practice one group, occasionally two —
  # and each group is one query.
  def completions_by_billing(billings, families)
    totals = Hash.new(0)

    billings.group_by { |billing| Quotas.period_start(billing) }.each do |period_start, group|
      owner = owner_by_id(group, families)

      CompletedSubmitter.where(account_id: owner.keys, is_first: true, completed_at: period_start..)
                        .group(:account_id).count
                        .each { |account_id, count| totals[owner.fetch(account_id)] += count }
    end

    totals
  end

  # Documents sent this month, per billing account (Quotas.sends_this_month):
  # the durable counters of the whole family, less the snapshot taken where a
  # downgrade started the free month.
  def sends_by_billing(billings, families)
    owner = owner_by_id(billings, families)
    totals = Hash.new(0)

    AccountCounter.where(account_id: owner.keys, key: 'submissions_created',
                         period: AccountCounters.month_period)
                  .pluck(:account_id, :value)
                  .each { |account_id, value| totals[owner.fetch(account_id)] += value }

    apply_downgrade_offsets(billings, totals)
  end

  # The offset is the BILLING account's own counter and only ever counts on
  # the free plan (Quotas.downgrade_sends_offset), so it is subtracted here
  # rather than inside the roll-up above.
  def apply_downgrade_offsets(billings, totals)
    offsets = AccountCounter.where(account_id: billings.map(&:id), key: Quotas::DOWNGRADE_SENDS_OFFSET_KEY,
                                   period: AccountCounters.month_period)
                            .pluck(:account_id, :value).to_h

    billings.to_h do |billing|
      counted = totals.fetch(billing.id, 0)
      offset = Plans.key_for(billing) == Plans::FREE ? offsets.fetch(billing.id, 0) : 0

      [billing.id, [counted - offset, 0].max]
    end
  end

  # Documents waiting for signatures, per billing account (Quotas.in_flight) —
  # the quota engine's own scope, grouped instead of counted one at a time.
  def in_flight_by_billing(families)
    owner = owner_by_id_from(families)
    totals = Hash.new(0)

    Quotas.in_flight_scope(owner.keys).group(:account_id).count
          .each { |account_id, count| totals[owner.fetch(account_id)] += count }

    totals
  end

  # Seats taken, per billing account (Accounts.seat_occupancy): the people who
  # hold one plus the invitations holding one for somebody who has not arrived.
  def seats_by_billing(seat_families)
    owner = owner_by_id_from(seat_families)
    totals = Hash.new(0)

    Accounts.seat_holders(owner.keys).group(:account_id).count
            .each { |account_id, count| totals[owner.fetch(account_id)] += count }
    AccountInvite.pending.where(account_id: owner.keys).group(:account_id).count
                 .each { |account_id, count| totals[owner.fetch(account_id)] += count }

    totals
  end

  # child (or self) id → the billing id it rolls up to.
  def owner_by_id(billings, families)
    owner_by_id_from(families.slice(*billings.map(&:id)))
  end

  def owner_by_id_from(families)
    families.each_with_object({}) do |(billing_id, ids), owner|
      ids.each { |id| owner[id] = billing_id }
    end
  end

  # --- storage ----------------------------------------------------------------

  # Bytes stored, per billing account: `Quotas::Storage.bytes_used` for a whole
  # page at once.
  #
  # This is the ONE number that could not be batched by grouping an existing
  # Quotas scope, because `Quotas::Storage.direct_attachments` builds an OR
  # over five record types and keeps no column saying which account each
  # attachment belongs to. So the join back to the owner is written out here —
  # the same five owners, plus the preview images that hang off their
  # attachments, plus the same "each blob counted once" rule.
  #
  # It is a SECOND expression of one rule, which is exactly the shape that
  # drifts, so the golden spec pins it: an account holding a blob of every
  # kind must come back byte-for-byte equal to `Quotas::Storage.bytes_used`,
  # and the record types this SQL names must be the record types that method
  # names.
  OWNED_ATTACHMENTS_SQL = <<~SQL.squish
    WITH owned AS (
      SELECT att.id AS attachment_id, att.blob_id, t.account_id
        FROM active_storage_attachments att
        JOIN templates t ON t.id = att.record_id
       WHERE att.record_type = 'Template' AND t.account_id IN (:ids)
      UNION ALL
      SELECT att.id, att.blob_id, s.account_id
        FROM active_storage_attachments att
        JOIN submissions s ON s.id = att.record_id
       WHERE att.record_type = 'Submission' AND s.account_id IN (:ids)
      UNION ALL
      SELECT att.id, att.blob_id, sub.account_id
        FROM active_storage_attachments att
        JOIN submitters sub ON sub.id = att.record_id
       WHERE att.record_type = 'Submitter' AND sub.account_id IN (:ids)
      UNION ALL
      SELECT att.id, att.blob_id, u.account_id
        FROM active_storage_attachments att
        JOIN users u ON u.id = att.record_id
       WHERE att.record_type = 'User' AND u.account_id IN (:ids)
      UNION ALL
      SELECT att.id, att.blob_id, att.record_id
        FROM active_storage_attachments att
       WHERE att.record_type = 'Account' AND att.record_id IN (:ids)
    ), with_previews AS (
      SELECT attachment_id, blob_id, account_id FROM owned
      UNION ALL
      SELECT prev.id, prev.blob_id, owned.account_id
        FROM active_storage_attachments prev
        JOIN owned ON owned.attachment_id = prev.record_id
       WHERE prev.record_type = 'ActiveStorage::Attachment'
    )
    SELECT account_id, COALESCE(SUM(blobs.byte_size), 0) AS bytes
      FROM (SELECT DISTINCT account_id, blob_id FROM with_previews) distinct_blobs
      JOIN active_storage_blobs blobs ON blobs.id = distinct_blobs.blob_id
     GROUP BY account_id
  SQL

  def storage_by_billing(families)
    owner = owner_by_id_from(families)
    totals = Hash.new(0)

    bytes_by_account(owner.keys).each { |account_id, bytes| totals[owner.fetch(account_id)] += bytes }

    totals
  end

  # account id → bytes stored by that account alone (no roll-up).
  def bytes_by_account(ids)
    return {} if ids.blank?

    sql = ApplicationRecord.sanitize_sql_array([OWNED_ATTACHMENTS_SQL, { ids: }])

    ApplicationRecord.connection.select_rows(sql).to_h { |account_id, bytes| [account_id.to_i, bytes.to_i] }
  end

  # The accounts among `scope` whose stored bytes are over the cap their plan
  # (and the operator's overrides) give them. Bounded by STORAGE_SCAN_LIMIT:
  # the answer is [ids, truncated?], so the page can say when it stopped.
  def over_storage_cap(scope)
    # Ordered before it is cut, so "the first 500" is the same 500 on every
    # request rather than whatever the database handed back first.
    accounts = scope.reorder(:id).limit(STORAGE_SCAN_LIMIT + 1).to_a
    truncated = accounts.size > STORAGE_SCAN_LIMIT
    accounts = accounts.first(STORAGE_SCAN_LIMIT)
    usage = usage_for(accounts)

    over = accounts.select do |account|
      limit = usage.fetch(account.id).limits.storage_bytes

      limit.present? && usage.fetch(account.id).storage_bytes > limit
    end

    [over.map(&:id), truncated]
  end

  # --- Stripe -----------------------------------------------------------------

  # Where an id on the billing panel links to. Read from the secret key's own
  # prefix (StripeBilling.key_mode), never from the key itself — no Stripe key
  # is ever rendered — and nil when there is no configured mode to be sure of,
  # so a link is either right or absent.
  # The dashboard itself, for the "open Stripe" link on the billing tab. Same
  # rule as the deep links below: read from the key's own mode, and nil when
  # there is no mode to be sure of, so the link is either right or absent.
  def stripe_dashboard_root
    case StripeBilling.key_mode
    when 'test' then 'https://dashboard.stripe.com/test'
    when 'live' then 'https://dashboard.stripe.com'
    end
  end

  def stripe_dashboard_url(object, id)
    return nil if id.blank?

    segment = { customer: 'customers', subscription: 'subscriptions', price: 'prices',
                product: 'products' }[object.to_sym]

    return nil if segment.nil?

    case StripeBilling.key_mode
    when 'test' then "https://dashboard.stripe.com/test/#{segment}/#{id}"
    when 'live' then "https://dashboard.stripe.com/#{segment}/#{id}"
    end
  end
end
