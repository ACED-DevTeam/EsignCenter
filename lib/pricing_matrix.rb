# frozen_string_literal: true

# The public pricing page (/pricing) as data. Every row is built from the
# constants that actually enforce it — Quotas::Limits for the numbers,
# Entitlements for which features a free account is refused, StripeBilling for
# the price and the trial — so the page can never drift from the product.
#
# Coverage is checked when this file loads: every symbol in
# Entitlements::PAID_ONLY must appear in some row's `features`, so adding a
# matrix row without a pricing row fails the suite instead of silently selling
# less than we gate.
module PricingMatrix
  # The word the paid column shows where the free column shows a number. Paid
  # in-app sending is never auto-blocked by a quota (D42); the fair-use review
  # threshold behind it lives in the Terms, which the page links beside it.
  UNLIMITED = 'Unlimited'

  # Presentation groups, in reading order. A view iterates `groups` and reads
  # `rows_for(group)`; the group keys double as i18n keys (pricing_group_*).
  GROUPS = %i[signing limits automation branding].freeze

  module_function

  def price_per_seat
    StripeBilling::PRICE_PER_SEAT_USD
  end

  def trial_days
    StripeBilling::TRIAL_PERIOD_DAYS
  end

  def business_price
    StripeBilling::BUSINESS_BASE_USD
  end

  def api_pack_price
    StripeBilling::API_PACK_USD
  end

  def paid_api_completions
    Quotas::Limits::PAID_API_COMPLETIONS_PER_MONTH
  end

  def business_api_completions
    Quotas::Limits::BUSINESS_API_COMPLETIONS_PER_MONTH
  end

  def api_pack_completions
    Quotas::Limits::API_PACK_COMPLETIONS_PER_MONTH
  end

  def free_completions
    Quotas::Limits::FREE_COMPLETIONS_PER_MONTH
  end

  def free_sends
    Quotas::Limits::FREE_SENDS_PER_MONTH
  end

  def free_in_flight
    Quotas::Limits::FREE_IN_FLIGHT
  end

  def free_seats
    Quotas::Limits::FREE_SEATS
  end

  def fair_use_completions_per_seat
    Quotas::Limits::PAID_COMPLETIONS_REVIEW_PER_SEAT
  end

  # `free` / `paid` / `business` are true (included), false (not on this plan) or a string
  # (a value). `features` names the Entitlements symbols a row stands for;
  # `fair_use` marks a paid "Unlimited" that the Terms' fair-use rule bounds.
  def rows
    @rows ||= [
      row(:send_and_sign, :signing, true, true),
      row(:templates_folders, :signing, true, true),
      row(:audit_trail, :signing, true, true),
      row(:signing_flow, :signing, true, true),
      row(:signer_2fa, :signing, true, true),
      row(:word_uploads, :signing, true, true),
      row(:exports, :signing, true, true),

      row(:completions, :limits, free_completions.to_s, UNLIMITED, fair_use: true),
      row(:api_completions, :limits, false, paid_api_completions.to_s, business: business_api_completions.to_s),
      row(:api_packs, :limits, false, "+#{api_pack_completions} for $#{api_pack_price}/mo"),
      row(:sends, :limits, free_sends.to_s, UNLIMITED, fair_use: true),
      row(:in_flight, :limits, free_in_flight.to_s, UNLIMITED, fair_use: true),
      row(:storage, :limits, true, true),
      row(:seats, :limits, free_seats.to_s, "$#{price_per_seat} per user per month",
          business: "1 included; $#{price_per_seat} per extra user per month"),

      row(:api, :automation, false, true, features: %i[api mcp webhooks signing_sessions]),
      row(:conditional_logic, :automation, false, true, features: %i[conditional_logic]),
      row(:reminders, :automation, false, true, features: %i[reminders]),
      row(:embed, :automation, false, true, features: %i[embed]),
      row(:delivery_tracking, :automation, false, true, features: %i[delivery_tracking]),

      row(:logo_upload, :branding, true, true),
      row(:branding_removal, :branding, false, true, features: %i[branding_removal]),
      row(:custom_email_templates, :branding, false, true, features: %i[custom_email_templates]),
      row(:account_smtp, :branding, false, true, features: %i[account_smtp]),
      row(:bcc, :branding, false, true, features: %i[bcc]),
      row(:download_links, :branding, true, true)
    ].freeze
  end

  def rows_for(group)
    rows.select { |item| item[:group] == group }
  end

  def groups
    GROUPS
  end

  # The union of every row's features: what the page promises the paid plan.
  def covered_features
    rows.flat_map { |item| item[:features] }.uniq
  end

  def unmapped_paid_only_features
    Entitlements::PAID_ONLY - covered_features
  end

  def row(key, group, free, paid, business: paid, features: [], fair_use: false)
    label_key = %i[completions sends].include?(key) ? "pricing_row_in_app_#{key}" : "pricing_row_#{key}"

    { key:, group:, label_key:, free:, paid:, business:, enterprise: group == :limits ? 'Custom' : true, features:,
      fair_use: }
  end

  unless unmapped_paid_only_features.empty?
    raise "PricingMatrix has no row for paid-only features: #{unmapped_paid_only_features.join(', ')}"
  end
end
