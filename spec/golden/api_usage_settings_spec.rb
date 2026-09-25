# frozen_string_literal: true

# The two settings pages read the same live quota and billing-account rollup;
# price configuration controls purchases without hiding existing capacity.
RSpec.describe 'API usage settings', type: :request do
  stash_env 'BILLING_ENABLED', 'STRIPE_BUSINESS_PRICE_ID', 'STRIPE_API_PACK_PRICE_ID', clear: true

  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let!(:subscription) do
    create(:account_subscription, account:, status: 'active', stripe_subscription_id: 'sub_usage', plan: 'business',
                                  quantity: 3, api_pack_quantity: 2)
  end

  before do
    ENV['BILLING_ENABLED'] = 'true'
    sign_in user
  end

  def page(path)
    get path

    expect(response).to have_http_status(:ok)

    Nokogiri::HTML(response.body)
  end

  it 'shows the billing-account allowance and UTC reset on both pages' do
    travel_to Time.utc(2026, 9, 23) do
      ['/settings/billing', '/settings/api'].each do |path|
        meter = page(path).at_css('[data-api-usage]').text.squish

        expect(meter).to include('API completions this month: 0 of 600')
        expect(meter).to include('October 01, 2026 (UTC)')
      end
    end
  end

  it 'discloses unavailable pack purchases while retaining Business pricing and capacity' do
    doc = page('/settings/billing')

    expect(doc.at_css('[data-billing-amount]').text.squish).to eq('$89 per month')
    expect(doc.at_css('[data-billing-state-badge]').text).to eq('Business plan')
    expect(doc.at_css('[data-billing-api-capacity]').text).to include('API pack purchases are not available yet.')
    expect(doc.css("form[action='/settings/billing/api_packs']")).to be_empty
    expect(doc.css("form[action='/settings/billing/plan']")).to be_empty
  end

  it 'offers recurring quantities and a prorated switch when optional prices are configured' do
    ENV['STRIPE_BUSINESS_PRICE_ID'] = 'price_business'
    ENV['STRIPE_API_PACK_PRICE_ID'] = 'price_packs'
    subscription.update!(plan: 'paid')

    doc = page('/settings/billing')

    expect(doc.at_css("form[action='/settings/billing/plan'] input[name='plan']")['value']).to eq('business')
    expect(doc.at_css("form[action='/settings/billing/api_packs'] input[name='quantity']")['value']).to eq('2')
    expect(doc.at_css('[data-billing-api-capacity]').text)
      .to include('Removing packs lowers your bill and capacity at renewal.')
  end

  it 'offers trial packs that are paid for when added' do
    ENV['STRIPE_API_PACK_PRICE_ID'] = 'price_packs'
    subscription.update!(plan: 'paid', status: 'trialing', access_state: 'trialing', stripe_status: 'trialing',
                         trial_end: 10.days.from_now)

    doc = page('/settings/billing')

    expect(doc.at_css("form[action='/settings/billing/api_packs']")).to be_present
    expect(doc.at_css('[data-billing-api-capacity]').text).to include('Packs are not free during your trial')
  end

  it 'keeps Business visible until a scheduled downgrade and offers cancellation' do
    ENV['STRIPE_BUSINESS_PRICE_ID'] = 'price_business'
    subscription.update!(plan: 'paid', retained_business_until: 10.days.from_now)

    doc = page('/settings/billing')

    expect(doc.at_css('[data-api-usage]').text).to include('0 of 600')
    expect(doc.at_css('[data-billing-pending-plan]').text).to include('Your plan changes to Paid')
    expect(doc.at_css("form[action='/settings/billing/plan']").text).to include('Keep Business')
  end

  [0, 200, -1].each do |limit|
    it "hides plan and pack controls for an agreement override of #{limit}" do
      ENV['STRIPE_BUSINESS_PRICE_ID'] = 'price_business'
      ENV['STRIPE_API_PACK_PRICE_ID'] = 'price_packs'
      AccountLimitOverride.create!(account:, api_completions_per_month: limit)

      doc = page('/settings/billing')

      expect(doc.at_css('[data-billing-capacity-agreement]').text).to include('capacity is set by your agreement')
      expect(doc.css("form[action='/settings/billing/plan'], form[action='/settings/billing/api_packs']")).to be_empty
    end
  end

  it 'shows the parent allowance and no purchase controls to a linked child' do
    child = create(:account)
    AccountLinkedAccount.create!(account:, linked_account: child)
    sign_out user
    sign_in create(:user, account: child)

    doc = page('/settings/billing')

    expect(doc.at_css('[data-api-usage]').text).to include('0 of 600')
    expect(doc.css('[data-billing-api-capacity]')).to be_empty
  end
end
