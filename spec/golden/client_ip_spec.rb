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
end
