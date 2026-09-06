# frozen_string_literal: true

RSpec.describe 'Visitor IP handling', type: :request do
  before { RateLimit.store.clear }
  after { RateLimit.store.clear }

  def resolved_ip(forwarded_for)
    request = ActionDispatch::TestRequest.create(
      'REMOTE_ADDR' => '10.226.90.65',
      'HTTP_X_FORWARDED_FOR' => forwarded_for
    )

    ActionDispatch::RemoteIp::GetIp.new(request, true, TrustedProxies.all).to_s
  end

  def post_verify(headers)
    post '/verify', headers: {
      'REMOTE_ADDR' => '10.226.90.65',
      'HTTP_X_FORWARDED_FOR' => '81.97.145.24, 10.226.90.65'
    }.merge(headers)
  end

  it 'resolves the visitor through the real Cloudflare and Render proxy list' do
    chain = '81.97.145.24, 172.71.195.123, 10.226.90.65'

    expect(resolved_ip(chain)).to eq('81.97.145.24')
    expect(resolved_ip("9.9.9.9, #{chain}")).to eq('81.97.145.24')
  end

  it 'keeps every Rails default proxy and trusts the Cloudflare edge range' do
    expect(TrustedProxies.all).to include(*ActionDispatch::RemoteIp::TRUSTED_PROXIES)
    expect(TrustedProxies.all).to include(IPAddr.new('172.64.0.0/13'))
    expect(TrustedProxies.all.any? { |proxy| proxy.include?(IPAddr.new('172.71.195.123')) }).to be(true)
  end

  it 'ignores Forwarded and charges the request to its real IP bucket' do
    post_verify('HTTP_FORWARDED' => 'for=9.9.9.9')

    expect(response).to have_http_status(:unprocessable_content)
    expect(RateLimit.store.read('verify-minute-9.9.9.9')).to be_nil
    expect(RateLimit.store.read('verify-minute-81.97.145.24')).to eq(1)
  end

  it 'ignores Client-Ip without raising an IP spoofing error' do
    post_verify('HTTP_CLIENT_IP' => '9.9.9.9')

    expect(response).to have_http_status(:unprocessable_content)
    expect(RateLimit.store.read('verify-minute-9.9.9.9')).to be_nil
    expect(RateLimit.store.read('verify-minute-81.97.145.24')).to eq(1)
  end

  # D77(B). The two examples above prove the BEHAVIOUR in the test
  # environment, where the proxy list is passed to GetIp by hand and the
  # middleware is exercised through the stack. Neither of them would notice
  # the production wiring being deleted: the test environment never loads
  # config/environments/production.rb, so the line that hands the same list to
  # Rails on Render is unreachable from here except as text. These three read
  # it. Together they are the CI half of the launch gate; the other half is
  # the measured-IP walk in docs/render-deploy-checklist.md, which no test can
  # stand in for because only a real request through Cloudflare knows what
  # Cloudflare puts in the chain.
  describe 'the production wiring itself' do
    # Line-anchored, not `include`. A substring match is passed by the line
    # commented out — one `#` and the production wiring is dead while the
    # assertion stays green (review 2, M3) — and the behavioural examples
    # above cannot notice, because they build the list by hand.
    it 'hands the trusted-proxy list to Rails in the production environment file' do
      production_config = Rails.root.join('config/environments/production.rb').read

      expect(production_config).to match(/^\s*config\.action_dispatch\.trusted_proxies\s*=\s*TrustedProxies\.all\s*$/)
      expect(production_config).to match(%r{^\s*require_relative\s+'\.\./\.\./lib/trusted_proxies'\s*$})

      # And nothing else assigns it, so the line above is the whole answer.
      expect(production_config.scan(/^\s*config\.action_dispatch\.trusted_proxies\s*=/).size).to eq(1)
    end

    it 'drops both spoofable client-IP headers in the middleware' do
      middleware_source = Rails.root.join('lib/normalize_client_ip_middleware.rb').read

      expect(middleware_source).to match(/^\s*env\.delete\('HTTP_FORWARDED'\)\s*$/)
      expect(middleware_source).to match(/^\s*env\.delete\('HTTP_CLIENT_IP'\)\s*$/)
    end

    it 'keeps that middleware in the stack, ahead of anything that reads an IP' do
      middlewares = Rails.application.middleware.map { |middleware| middleware.klass.to_s }

      expect(middlewares).to include('NormalizeClientIpMiddleware', 'ActionDispatch::RemoteIp')
      expect(middlewares.index('NormalizeClientIpMiddleware'))
        .to be < middlewares.index('ActionDispatch::RemoteIp')
    end
  end
end
