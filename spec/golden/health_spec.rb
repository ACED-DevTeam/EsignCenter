# frozen_string_literal: true

# /up is the uptime probe: anonymous, JSON, 200 only when the database and
# Redis both answer. The scheduler heartbeat is reported but never decides
# the status. Redis here is the real one the test process shares with Sidekiq.
RSpec.describe 'Health check', type: :request do
  let(:tick_key) { SchedulerHeartbeatJob::LAST_TICK_KEY }

  before do
    Sidekiq.redis { |conn| conn.call('DEL', tick_key) }
  end

  after do
    Sidekiq.redis { |conn| conn.call('DEL', tick_key) }
  end

  it 'answers 200 with the JSON shape when the database and Redis respond' do
    get '/up'

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('application/json')
    expect(response.parsed_body).to eq(
      'status' => 'ok', 'db' => 'ok', 'redis' => 'ok', 'scheduler_last_tick_at' => nil
    )
  end

  it 'reports the last scheduler tick without letting staleness change the status' do
    Sidekiq.redis { |conn| conn.call('SET', tick_key, '2020-01-01T00:00:00Z') }

    get '/up'

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('status' => 'ok', 'scheduler_last_tick_at' => '2020-01-01T00:00:00Z')
  end

  it 'answers 503 when Redis is unreachable' do
    allow(Sidekiq).to receive(:redis).and_raise(RedisClient::CannotConnectError, 'refused')

    get '/up'

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq(
      'status' => 'degraded', 'db' => 'ok', 'redis' => 'error', 'scheduler_last_tick_at' => nil
    )

    # Let the cleanup hook reach Redis again.
    allow(Sidekiq).to receive(:redis).and_call_original
  end

  it 'answers 503 when the database does not respond' do
    allow(ActiveRecord::Base).to receive(:lease_connection).and_raise(ActiveRecord::ConnectionNotEstablished, 'down')

    get '/up'

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to include('status' => 'degraded', 'db' => 'error', 'redis' => 'ok')
  end

  # No user exists at this point, so anything routed through
  # ApplicationController would redirect to the setup wizard.
  it 'needs no session, no user and sets no cookie' do
    expect(User.exists?).to be(false)

    get '/up'

    expect(response).to have_http_status(:ok)
    expect(response.headers['Set-Cookie']).to be_nil
  end
end
