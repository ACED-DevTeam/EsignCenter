# frozen_string_literal: true

describe OutboundAddress do
  it 'blocks the reserved IPv6 ranges and IPv4 embedded in NAT64/6to4/Teredo forms' do
    %w[fec0::1 feff::1 64:ff9b::a00:1 64:ff9b:1::1 2002:a00:1::1 2001::1 fd12::1 fe80::1 ::1 ::ffff:10.0.0.1]
      .each { |ip| expect(described_class.blocked_ip?(described_class.parse_ip(ip))).to be(true), ip }
  end

  it 'leaves ordinary public addresses alone' do
    %w[8.8.8.8 93.184.215.14 2606:4700:4700::1111 2a00:1450:4001::1]
      .each { |ip| expect(described_class.blocked_ip?(described_class.parse_ip(ip))).to be(false), ip }
  end
end
