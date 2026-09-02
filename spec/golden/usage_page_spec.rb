# frozen_string_literal: true

# Every account can see its own usage honestly at /settings/usage: live
# counts against every cap, an over-cap number shown as it is (never
# clamped), the UTC reset date, the sending-pause banner, the free upgrade
# call-to-action, and a plain "no limits apply" page for internal accounts.
# Completions here are REAL signer completions (SigningHelpers#complete!).
RSpec.describe 'Usage page', type: :request do
  let!(:free_account) { create(:account) }
  let!(:paid_account) { create(:account, :paid, seats: 2) }
  let!(:internal_account) { create(:account, :internal) }
  let(:admins) { {} }

  before { platform_certificate! }

  def admin_for(account)
    admins[account.id] ||= create(:user, account:)
  end

  def act_as(account)
    sign_out(:user)
    reset!
    sign_in(admin_for(account))
  end

  # No PDF and no completion mail: the metering path alone (see quota_spec).
  def fast_template_for(account)
    template = create(:template, account:, author: admin_for(account), only_field_types: %w[text],
                                 attachment_count: 0,
                                 preferences: { 'completed_notification_email_enabled' => false,
                                                'documents_copy_email_enabled' => false })
    template.update!(fields: [{ 'uuid' => SecureRandom.uuid, 'submitter_uuid' => template.submitters.first['uuid'],
                                'name' => 'Name', 'type' => 'text', 'required' => true, 'areas' => [] }])
    template
  end

  def send_one(account, template:)
    Submissions.create_from_emails(template:, user: admin_for(account), source: :invite, mark_as_sent: true,
                                   emails: "signer-#{SecureRandom.hex(4)}@example.com").sole
  end

  def page
    get '/settings/usage'

    expect(response).to have_http_status(:ok)

    Nokogiri::HTML(response.body)
  end

  def card(doc, key)
    doc.at("[data-usage-card=\"#{key}\"]")
  end

  def of(used, limit)
    I18n.t('usage_of', used:, limit:)
  end

  it 'shows a free account its numbers against every cap, the reset date and the upgrade call-to-action',
     sidekiq: :inline do
    template = fast_template_for(free_account)
    sent = Array.new(3) { send_one(free_account, template:) }
    complete!(sent.first.submitters.first)
    act_as(free_account)

    doc = page

    expect(doc.at('[data-usage-plan]')['data-usage-plan']).to eq('free')
    expect(doc.at('[data-usage-plan]').text).to include(I18n.t('usage_plan_free'))
    expect(card(doc, 'completions').text).to include(of(1, 5))
    expect(card(doc, 'sends').text).to include(of(3, 15))
    expect(card(doc, 'in_flight').text).to include(of(2, 10))
    stored = ActiveSupport::NumberHelper.number_to_human_size(Quotas::Storage.bytes_used(free_account))
    expect(Quotas::Storage.bytes_used(free_account)).to be_positive # the signed PDF
    expect(card(doc, 'storage').text).to include(of(stored, '1 GB'))
    expect(card(doc, 'seats').text).to include(of(1, 1))
    # The one seat is taken — the ordinary state of a free account, shown
    # neutral — and no cap has been hit.
    expect(doc.css('[data-limit-reached]')).to be_empty
    expect(card(doc, 'seats').at('[data-all-seats-in-use]').text).to eq(I18n.t('all_seats_in_use'))
    expect(card(doc, 'seats').at('progress')['class']).not_to include('progress-error')
    expect(card(doc, 'completions').at('progress')['value']).to eq('20')

    reset = doc.at('[data-usage-reset]').text
    local = Quotas.resets_at.in_time_zone(free_account.timezone)
    # The page renders in the account locale (en-US), which formats dates
    # and times its own way.
    I18n.with_locale(free_account.locale) do
      expect(reset).to include(I18n.t('limits_reset_on_utc', date: I18n.l(Quotas.resets_at.to_date, format: :long)))
      expect(reset).to include(I18n.t('limits_reset_in_your_timezone', time: I18n.l(local, format: :long),
                                                                       zone: local.zone))
    end
    expect(reset).to include('00:00 UTC')

    expect(doc.at('[data-usage-upgrade]')).to be_present
    expect(doc.at('[data-usage-upgrade] [data-upgrade-cta]').text).to include(I18n.t('upgrade_plan'))
    expect(doc.at('[data-usage-upgrade]').text).to include('$10 per user per month')
    expect(doc.at('[data-sending-paused-banner]')).to be_nil
    expect(doc.at('#account_settings_menu a[href="/settings/usage"]').text).to eq(I18n.t('usage'))
  end

  it 'shows the reset moment in the account timezone, not only UTC' do
    free_account.update!(timezone: 'Eastern Time (US & Canada)')
    act_as(free_account)

    local = Quotas.resets_at.in_time_zone('Eastern Time (US & Canada)')
    reset = page.at('[data-usage-reset]').text

    I18n.with_locale(free_account.locale) do
      expect(reset).to include(I18n.t('limits_reset_in_your_timezone', time: I18n.l(local, format: :long),
                                                                       zone: local.zone))
    end
    expect(local.hour).to be_between(19, 20) # the evening before, US Eastern
    expect(reset).to include(local.zone)
  end

  it 'shows an over-cap count as it is: 7 of 5 with a full bar and the limit badge', sidekiq: :inline do
    template = fast_template_for(free_account)
    # Seven documents sent while still under the completion cap, then all
    # seven complete: completion is never refused, so the account passes 5.
    sent = Array.new(7) { send_one(free_account, template:) }
    sent.each { |submission| complete!(submission.submitters.first) }
    expect(Quotas.completions_this_month(free_account)).to eq(7)
    act_as(free_account)

    doc = page
    completions = card(doc, 'completions')

    expect(completions.text).to include(of(7, 5))
    expect(completions.text).not_to include(of(5, 5))
    expect(completions.at('[data-limit-reached]').text).to eq(I18n.t('limit_reached'))
    expect(completions.at('progress')['value']).to eq('100')
    expect(completions.at('progress')['class']).to include('progress-error')
    expect(card(doc, 'in_flight').text).to include(of(0, 10))
    expect(card(doc, 'sends').at('[data-limit-reached]')).to be_nil
  end

  it 'shows a paid account plain counts with the fair-use note, seat-scaled storage and no call-to-action' do
    act_as(paid_account)

    doc = page

    expect(doc.at('[data-usage-plan]')['data-usage-plan']).to eq('paid')
    expect(doc.at('[data-usage-plan]').text).to include(I18n.t('usage_plan_paid'), I18n.t('seats_label', count: 2))
    expect(card(doc, 'completions').text).to include(I18n.t('fair_use_per_seat', count: 500))
    expect(card(doc, 'completions').text).not_to include(' of ')
    expect(card(doc, 'completions').at('progress')).to be_nil
    expect(card(doc, 'storage').text).to include(of(ActiveSupport::NumberHelper.number_to_human_size(0), '20 GB'))
    expect(card(doc, 'seats').text).to include(of(1, 2))
    expect(doc.at('[data-usage-upgrade]')).to be_nil
  end

  it 'shows the sending-paused banner with the complaint reason and the support address', sidekiq: :inline do
    SendingPause.pause!(free_account, reason: 'complaint')
    act_as(free_account)

    banner = page.at('[data-sending-paused-banner]')

    expect(banner).to be_present
    expect(banner.at('[data-sending-pause-reason="complaint"]').text).to eq(I18n.t('sending_pause_reason_complaint'))
    expect(banner.text).not_to include(I18n.t('sending_pause_reason_bounce_rate'))
    expect(banner.text).to include(I18n.t('sending_paused_banner', email: Docuseal::SUPPORT_EMAIL))
    expect(banner.text).to include(Docuseal::SUPPORT_EMAIL)
  end

  it 'names the bounce rate as the reason when that is what paused sending', sidekiq: :inline do
    SendingPause.pause!(free_account, reason: 'bounce_rate')
    act_as(free_account)

    banner = page.at('[data-sending-paused-banner]')

    expect(banner.at('[data-sending-pause-reason="bounce_rate"]').text)
      .to eq(I18n.t('sending_pause_reason_bounce_rate'))
    expect(banner.text).not_to include(I18n.t('sending_pause_reason_complaint'))
    expect(banner.text).to include(I18n.t('sending_paused_banner', email: Docuseal::SUPPORT_EMAIL))
  end

  it 'shows seats neutral at 1 of 1 and red only past the seats, at 2 of 1' do
    act_as(free_account)

    seats = card(page, 'seats')

    expect(seats.text).to include(of(1, 1))
    expect(seats.at('[data-all-seats-in-use]').text).to eq(I18n.t('all_seats_in_use'))
    expect(seats.at('[data-limit-reached]')).to be_nil
    expect(seats.at('progress')['class']).to include('progress-primary')

    # Two users on a one-seat account (a paid account that dropped to free).
    create(:user, account: free_account)

    seats = card(page, 'seats')

    expect(seats.text).to include(of(2, 1))
    expect(seats.at('[data-limit-reached]').text).to eq(I18n.t('limit_reached'))
    expect(seats.at('[data-all-seats-in-use]')).to be_nil
    expect(seats.at('progress')['class']).to include('progress-error')
    expect(seats.at('progress')['value']).to eq('100')
  end

  it 'tells an internal account that no limits apply and shows its raw numbers' do
    act_as(internal_account)

    doc = page

    expect(doc.at('[data-usage-plan]')['data-usage-plan']).to eq('internal')
    expect(doc.text).to include(I18n.t('no_limits_apply'))
    expect(doc.css('[data-usage-card]')).to be_empty
    expect(doc.at('[data-usage-upgrade]')).to be_nil
    expect(doc.at('[data-usage-reset]')).to be_nil
    expect(doc.text).to include(I18n.t('documents_completed_this_month'), I18n.t('storage_used'))
  end

  it 'requires a signed-in user' do
    sign_out(:user)
    reset!

    get '/settings/usage'

    expect(response).to have_http_status(:redirect)
    expect(response.location).not_to include('/settings/usage')
  end
end
