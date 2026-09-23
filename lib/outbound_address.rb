# frozen_string_literal: true

require 'resolv'

# Where an outbound request to a user-supplied URL may connect. Shared by
# webhook delivery (SendWebhookRequest) and URL downloads (DownloadUtils) so
# both refuse the same targets and pin the same way.
#
# A host is checked as a literal IP AND through every address its name
# resolves to, and the request is then pinned to the checked address, so a
# name that points at an internal service is refused like the literal IP, and a
# DNS answer that changes between the check and the connect (rebinding) cannot
# move the request.
module OutboundAddress
  # Addresses no public receiver can legitimately live on: loopback, RFC 1918
  # and unique-local private space, link-local, carrier-grade NAT, benchmark,
  # documentation, multicast and the other reserved blocks. IPv6 also covers
  # deprecated site-local (fec0::/10), both NAT64 prefixes (a NAT64 gateway
  # would forward to the embedded IPv4 address), and 6to4/Teredo, which embed
  # an IPv4 address the same way.
  BLOCKED_NETWORKS = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
    192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24
    203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 255.255.255.255/32
    ::/96 64:ff9b::/96 64:ff9b:1::/48 100::/64 2001::/32 2001:db8::/32 2002::/16
    fc00::/7 fe80::/10 fec0::/10 ff00::/8
  ].map { |cidr| IPAddr.new(cidr) }.freeze

  # Cloud instance-metadata lives on link-local (169.254.169.254, fe80::/10).
  METADATA_NETWORKS = %w[169.254.0.0/16 fe80::/10].map { |cidr| IPAddr.new(cidr) }.freeze

  DNS_TIMEOUT = 3

  module_function

  # The literal IP, or every address the name resolves to ([] when it does not
  # resolve).
  def addresses(host)
    literal = literal_ip(host)

    literal ? [literal] : resolve(host)
  end

  def resolve(host)
    dns = Resolv::DNS.new.tap { |resolver| resolver.timeouts = DNS_TIMEOUT }

    Resolv.new([Resolv::Hosts.new, dns]).getaddresses(host.to_s).filter_map { |address| parse_ip(address) }
  rescue Resolv::ResolvError, SystemCallError
    []
  ensure
    dns&.close
  end

  # Only the forms Ruby's resolver would connect to without a lookup; exotic
  # numeric spellings ("2130706433", "0x7f.1") are not IPs here, so they go
  # through resolution, find nothing and are refused as unresolvable.
  def literal_ip(host)
    parse_ip(host.to_s.downcase.delete_prefix('[').delete_suffix(']'))
  end

  def parse_ip(value)
    ip = IPAddr.new(value.to_s)
    ip.ipv4_mapped? ? ip.native : ip
  rescue IPAddr::Error
    nil
  end

  def blocked_ip?(ip)
    in_networks?(ip, BLOCKED_NETWORKS)
  end

  def metadata_ip?(ip)
    in_networks?(ip, METADATA_NETWORKS)
  end

  def in_networks?(ip, networks)
    networks.any? { |network| network.family == ip.family && network.include?(ip) }
  end

  # A connection that dials `address` (when given) instead of resolving the
  # URL's host again. Net::HTTP keeps the URL's hostname for SNI and
  # certificate verification, so pinning never weakens TLS. Callers must also
  # clear the per-request proxy (see `unproxied!`): a proxy would resolve the
  # host itself and undo the pin.
  def pinned_connection(address)
    Faraday.new do |faraday|
      faraday.adapter(:net_http) do |http|
        http.ipaddr = address if address
      end
    end
  end

  # Faraday fills the proxy from HTTP(S)_PROXY before the request block runs.
  def unproxied!(req, address)
    req.options.proxy = nil if address
  end
end
