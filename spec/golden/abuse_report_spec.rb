# frozen_string_literal: true

# A signer can report an abusive document anonymously from the signing and
# completed pages: each report is an AbuseFlag of kind document_report on
# the sending account (one row per report), the operator is alerted, an
# unknown slug is a 404, and the per-IP / per-document rate limits hold.
# The link lives outside the attribution partials, which stay untouched.
RSpec.describe 'Report this document', type: :request do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:) }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: author) }
  let(:submitter) { submission.submitters.first.tap { |s| s.update!(sent_at: Time.current) } }
  let(:deliveries) { ActionMailer::Base.deliveries }

  before do
    RateLimit.store.clear
    deliveries.clear
  end

  def report(slug, reason: 'phishing', details: 'Asks for my bank password.')
    post "/report/#{slug}", params: { reason:, details: }
  end

  it 'links to the report page from the signing page and from the completed page, outside the attribution' do
    get "/s/#{submitter.slug}"

    expect(response).to have_http_status(:ok)
    doc = Nokogiri::HTML(response.body)
    link = doc.at("a[href=\"/report/#{submitter.slug}\"]")
    expect(link.text).to eq(I18n.t('report_this_document'))
    expect(link.ancestors.map { |node| node['class'].to_s }.join(' ')).not_to include('powered')

    submitter.update!(completed_at: Time.current)

    get "/s/#{submitter.slug}/completed"

    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at("a[href=\"/report/#{submitter.slug}\"]").text)
      .to eq(I18n.t('report_this_document'))
  end

  it 'renders the form with the four reasons for a known slug, and 404s an unknown one' do
    get "/report/#{submitter.slug}"

    expect(response).to have_http_status(:ok)
    doc = Nokogiri::HTML(response.body)
    expect(doc.css('select[name="reason"] option').pluck('value').compact_blank)
      .to eq(%w[phishing spam impersonation other])
    expect(doc.text).to include(I18n.t('report_document_title'), I18n.t('report_reason_impersonation'))
    expect(doc.at('textarea[name="details"]')).to be_present

    expect { get '/report/no-such-slug' }.to raise_error(ActionController::RoutingError)
    expect { report('no-such-slug') }.to raise_error(ActionController::RoutingError)
    expect(AbuseFlag.count).to eq(0)
  end

  it 'records one document_report flag per report with the details and alerts the operator', sidekiq: :inline do
    report(submitter.slug)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t('report_submitted'))

    flag = AbuseFlag.where(kind: 'document_report').sole
    expect(flag.account).to eq(account)
    expect(flag.subject).to eq(submission)
    expect(flag.period).to eq('')
    expect(flag.resolved_at).to be_nil
    expect(flag.details).to include('reason' => 'phishing', 'details' => 'Asks for my bank password.',
                                    'submitter_slug' => submitter.slug, 'ip' => '127.0.0.1')
    expect(flag.details).to have_key('reporter_ua')

    alert = deliveries.sole
    expect(alert.to).to eq([Docuseal::SUPPORT_EMAIL])
    expect(alert.subject).to eq("[EsignCenter] Document reported (phishing) on account #{account.id}")
    expect(alert.body.encoded).to include("Submission: #{submission.id}", 'Reason: phishing', "Abuse flag: #{flag.id}")
    expect(alert['X-EC-Account-Id']).to be_nil

    report(submitter.slug, reason: 'spam', details: '')

    expect(AbuseFlag.where(kind: 'document_report', subject: submission).count).to eq(2)
    expect(deliveries.size).to eq(2)
  end

  it 'refuses a report without a valid reason and records nothing', sidekiq: :inline do
    report(submitter.slug, reason: '')

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t('report_choose_reason'))

    report(submitter.slug, reason: 'because')

    expect(response).to have_http_status(:unprocessable_content)
    expect(AbuseFlag.count).to eq(0)
    expect(deliveries).to be_empty
  end

  it 'limits one document to 3 reports and one network to 5 attempts per hour', sidekiq: :inline do
    other = create(:submission, :with_submitters, template:, created_by_user: author).submitters.first

    3.times { report(submitter.slug) }
    expect(AbuseFlag.count).to eq(3)

    # The 4th report on the same document is refused (and still counts as
    # this network's 4th attempt).
    report(submitter.slug)
    expect(response).to have_http_status(:too_many_requests)
    expect(response.body).to include(I18n.t('too_many_reports'))
    expect(AbuseFlag.count).to eq(3)

    # Another document: the 5th attempt from this network is taken...
    report(other.slug)
    expect(response).to have_http_status(:ok)
    expect(AbuseFlag.count).to eq(4)

    # ...and the 6th is refused by the network limit, well under the
    # document's own limit.
    report(other.slug)
    expect(response).to have_http_status(:too_many_requests)
    expect(AbuseFlag.count).to eq(4)
    expect(deliveries.size).to eq(4)
  end
end
