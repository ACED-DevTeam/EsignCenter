# frozen_string_literal: true

# POST /api/marketing/outreach: where the Mac automations report each day's
# outreach totals (docs/marketing-admin.md). A bearer token, no session.
RSpec.describe 'Marketing outreach endpoint', type: :request do
  stash_env 'MARKETING_OUTREACH_TOKEN', clear: true

  let(:token) { 'a-long-shared-outreach-token-0123456789' }
  let(:today) { MarketingAdmin.today }

  def report(body, token: self.token, raw: nil)
    headers = { 'Content-Type' => 'application/json' }
    headers['Authorization'] = "Bearer #{token}" if token

    post '/api/marketing/outreach', params: raw || body.to_json, headers:
  end

  def stored
    MarketingOutreachCount.order(:day, :kind).pluck(:day, :kind, :count)
  end

  it 'does not exist until a token is configured' do
    report({ emails_sent: 3 })

    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_empty
    expect(stored).to be_empty
  end

  it 'does not exist while the token is too short to be a secret, or is still the paste marker' do
    %w[short PASTE_YOUR_OUTREACH_TOKEN_HERE_0123456789].each do |weak|
      ENV['MARKETING_OUTREACH_TOKEN'] = weak

      report({ emails_sent: 3 }, token: weak)

      expect(response).to have_http_status(:not_found)
    end
  end

  context 'with a token configured' do
    before { ENV['MARKETING_OUTREACH_TOKEN'] = token }

    it 'refuses a missing or wrong token and stores nothing' do
      [nil, 'wrong-token', "#{token}x", ''].each do |given|
        report({ emails_sent: 3 }, token: given)

        expect(response).to have_http_status(:unauthorized)
      end

      expect(stored).to be_empty
    end

    it 'does not accept the token anywhere but the Authorization header' do
      post '/api/marketing/outreach', params: { emails_sent: 3, token: }.to_json,
                                      headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)

      post "/api/marketing/outreach?token=#{token}", params: { emails_sent: 3 }.to_json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'stores the day’s totals, for today in Chicago when no day is given' do
      report({ emails_sent: 12, replies: 2, reddit_comments: 3, facebook_group_comments: 1 })

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        'day' => today.iso8601, 'mode' => 'set',
        'counts' => { 'emails_sent' => 12, 'replies' => 2, 'reddit_comments' => 3, 'facebook_group_comments' => 1 }
      )
      expect(stored).to eq([[today, 'emails_sent', 12], [today, 'facebook_group_comments', 1],
                            [today, 'reddit_comments', 3], [today, 'replies', 2]])
    end

    it 'replaces a day’s number when the same report is sent again, and leaves the kinds it did not name' do
      report({ day: (today - 1).iso8601, emails_sent: 12, replies: 2 })
      report({ day: (today - 1).iso8601, emails_sent: 15 })

      expect(stored).to eq([[today - 1, 'emails_sent', 15], [today - 1, 'replies', 2]])
    end

    it 'adds to the day’s number in add mode' do
      report({ reddit_comments: 1, mode: 'add' })
      report({ reddit_comments: 1, mode: 'add' })
      report({ reddit_comments: 0, replies: 4, mode: 'add' })

      expect(response.parsed_body['counts']).to include('reddit_comments' => 2, 'replies' => 4)
      expect(stored).to eq([[today, 'reddit_comments', 2], [today, 'replies', 4]])
    end

    it 'works with no session, cookie or CSRF token, and sets none' do
      report({ emails_sent: 1 })

      expect(response).to have_http_status(:ok)
      expect(response.headers['Set-Cookie']).to be_nil
    end

    {
      'a count that is not a whole number' => [{ emails_sent: 'many' }, 'emails_sent must be a whole number'],
      'a count with a fraction' => [{ emails_sent: 12.5 }, 'emails_sent must be a whole number'],
      'a fraction written as text' => [{ replies: '3.7' }, 'replies must be a whole number'],
      'a count that is true rather than a number' => [{ replies: true }, 'replies must be a whole number'],
      'a count that is a list' => [{ replies: [3] }, 'replies must be a whole number'],
      'a count that is null' => [{ replies: nil }, 'replies must be a whole number'],
      'a mode that is not text' => [{ emails_sent: 1, mode: ['set'] }, 'mode must be one of'],
      'a day that is not text' => [{ emails_sent: 1, day: 20_261_121 }, 'day must look like'],
      'a day in another date format' => [{ emails_sent: 1, day: '2026-W47-6' }, 'day must look like'],
      'a day that does not exist' => [{ emails_sent: 1, day: '2026-02-31' }, 'day must look like'],
      'a negative count' => [{ replies: -1 }, 'replies must be a whole number'],
      'an absurd count' => [{ replies: 1_000_001 }, 'replies must be a whole number'],
      'no known kind at all' => [{ tweets: 4 }, 'send at least one of'],
      'an unknown mode' => [{ emails_sent: 1, mode: 'replace' }, 'mode must be one of'],
      'a day that is not a date' => [{ emails_sent: 1, day: 'yesterday' }, 'day must look like'],
      'a day in the future' => [{ emails_sent: 1, day: '2099-01-01' }, 'day cannot be after today'],
      'a day long past' => [{ emails_sent: 1, day: '2020-01-01' }, 'day cannot be more than 60 days ago']
    }.each do |what, (body, message)|
      it "refuses #{what} with a sentence the job can log" do
        report(body)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to include(message)
        expect(stored).to be_empty
      end
    end

    it 'accepts whole numbers however they are written, and stores them exactly' do
      report({ emails_sent: 12.0, replies: '3', reddit_comments: 0 })

      expect(response).to have_http_status(:ok)
      expect(stored).to eq([[today, 'emails_sent', 12], [today, 'reddit_comments', 0], [today, 'replies', 3]])
    end

    # "Today" is today in Chicago. Just after midnight UTC it is still
    # yesterday evening there, and tomorrow's date is refused.
    it 'refuses the day after Chicago’s today, even when it is already that day in UTC' do
      travel_to(Time.utc(2026, 11, 22, 3, 30)) do
        report({ day: '2026-11-22', emails_sent: 4 })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to include('day cannot be after today')

        report({ day: '2026-11-21', emails_sent: 4 })

        expect(response).to have_http_status(:ok)
        expect(stored).to eq([[Date.new(2026, 11, 21), 'emails_sent', 4]])
      end
    end

    it 'refuses a body that is not a JSON object' do
      ['[1, 2]', '{not json', '"emails"'].each do |raw|
        report(nil, raw:)

        expect(response).to have_http_status(:bad_request)
      end

      expect(stored).to be_empty
    end
  end
end
