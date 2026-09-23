# frozen_string_literal: true

# URL downloads fetch customer-supplied URLs (template upload by URL, file
# default values, the MCP create-template tool). Every hop, the first and each
# redirect, must be HTTPS, public and pinned to the address that was checked.
describe DownloadUtils do
  let(:public_ip) { IPAddr.new('93.184.215.14') }

  def resolves(host, *ips)
    allow(OutboundAddress).to receive(:resolve).with(host).and_return(ips.map { |ip| IPAddr.new(ip) })
  end

  describe 'validated downloads' do
    it 'downloads a public file, pinned to the checked address with the environment proxy off' do
      stub_request(:get, 'https://files.example.com/doc.pdf').to_return(body: '%PDF-1.4')
      allow(ENV).to receive(:[]).and_call_original
      %w[http_proxy HTTP_PROXY https_proxy HTTPS_PROXY].each do |key|
        allow(ENV).to receive(:[]).with(key).and_return('http://proxy.internal:3128')
      end
      allow(Net::HTTP).to receive(:new).and_call_original

      expect(described_class.call('https://files.example.com/doc.pdf', validate: true).body).to eq('%PDF-1.4')

      expect(Net::HTTP).to have_received(:new).with('files.example.com', 443, nil)
    end

    it 'dials the checked address' do
      stub_request(:get, 'https://files.example.com/doc.pdf').to_return(body: 'ok')
      dialled = []
      allow_any_instance_of(Net::HTTP).to receive(:ipaddr=).and_wrap_original do |original, address|
        dialled << address
        original.call(address)
      end

      described_class.call('https://files.example.com/doc.pdf', validate: true)

      expect(dialled).to eq(['93.184.215.14'])
    end

    ['https://10.0.0.5/f.pdf', 'https://192.168.1.10/f.pdf', 'https://172.16.4.4/f.pdf',
     'https://100.64.0.1/f.pdf', 'https://169.254.169.254/latest/meta-data', 'https://127.0.0.2/f.pdf',
     'https://[fd00::1]/f.pdf', 'https://[fe80::1]/f.pdf', 'https://[fec0::1]/f.pdf',
     'https://[64:ff9b::a00:5]/f.pdf', 'https://[64:ff9b:1::a00:5]/f.pdf', 'https://[::ffff:10.0.0.5]/f.pdf',
     'https://[2002:a00:5::1]/f.pdf'].each do |url|
      it "refuses the private literal #{url} without a request" do
        expect { described_class.call(url, validate: true) }
          .to raise_error(DownloadUtils::UnableToDownload, /private address/)
        expect(a_request(:any, /.*/)).not_to have_been_made
      end
    end

    it 'still refuses plain http and localhost with the existing messages' do
      expect { described_class.call('http://files.example.com/f.pdf', validate: true) }
        .to raise_error(DownloadUtils::UnableToDownload, /Only HTTPS is allowed/)
      expect { described_class.call('https://localhost/f.pdf', validate: true) }
        .to raise_error(DownloadUtils::UnableToDownload, /Can't download from localhost/)
    end

    it 'refuses a hostname that resolves to a private address, even alongside a public one' do
      resolves('internal.example.com', '93.184.215.14', '10.1.2.3')

      expect { described_class.call('https://internal.example.com/f.pdf', validate: true) }
        .to raise_error(DownloadUtils::UnableToDownload, /private address/)
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it 'refuses a hostname that does not resolve' do
      resolves('nowhere.example.com')

      expect { described_class.call('https://nowhere.example.com/f.pdf', validate: true) }
        .to raise_error(DownloadUtils::UnableToDownload, /Could not resolve host/)
    end

    it 'follows a redirect to another public host, checking and pinning each hop' do
      resolves('cdn.example.net', '93.184.216.34')
      stub_request(:get, 'https://files.example.com/doc.pdf')
        .to_return(status: 302, headers: { 'Location' => 'https://cdn.example.net/doc.pdf' })
      stub_request(:get, 'https://cdn.example.net/doc.pdf').to_return(body: 'final')
      dialled = []
      allow_any_instance_of(Net::HTTP).to receive(:ipaddr=).and_wrap_original do |original, address|
        dialled << address
        original.call(address)
      end

      expect(described_class.call('https://files.example.com/doc.pdf', validate: true).body).to eq('final')
      expect(dialled).to eq(['93.184.215.14', '93.184.216.34'])
    end

    it 'follows a relative redirect on the same host' do
      stub_request(:get, 'https://files.example.com/a').to_return(status: 301, headers: { 'Location' => '/b' })
      stub_request(:get, 'https://files.example.com/b').to_return(body: 'moved')

      expect(described_class.call('https://files.example.com/a', validate: true).body).to eq('moved')
    end

    it 'refuses a redirect to a host resolving to a private address, without requesting it' do
      resolves('intranet.example.com', '10.0.0.8')
      stub_request(:get, 'https://files.example.com/doc.pdf')
        .to_return(status: 302, headers: { 'Location' => 'https://intranet.example.com/secret' })

      expect { described_class.call('https://files.example.com/doc.pdf', validate: true) }
        .to raise_error(DownloadUtils::UnableToDownload, /private address/)
      expect(a_request(:get, 'https://intranet.example.com/secret')).not_to have_been_made
    end

    it 'refuses redirects to the metadata address, to http and to localhost' do
      {
        'https://169.254.169.254/latest/meta-data' => /private address/,
        'http://files.example.com/plain' => /Only HTTPS is allowed/,
        'https://localhost/admin' => /Can't download from localhost/
      }.each do |location, message|
        stub_request(:get, 'https://files.example.com/doc.pdf')
          .to_return(status: 302, headers: { 'Location' => location })

        expect { described_class.call('https://files.example.com/doc.pdf', validate: true) }
          .to raise_error(DownloadUtils::UnableToDownload, message)
      end

      expect(a_request(:get, /169\.254|localhost|http:/)).not_to have_been_made
    end

    ['https://[not-an-ip/x', 'https://exa mple.com:99999999999/x', 'http://[::1'].each do |location|
      it "turns the unparseable redirect #{location.inspect} into UnableToDownload" do
        stub_request(:get, 'https://files.example.com/doc.pdf')
          .to_return(status: 302, headers: { 'Location' => location })

        expect { described_class.call('https://files.example.com/doc.pdf', validate: true) }
          .to raise_error(DownloadUtils::UnableToDownload, /Invalid redirect/)
        expect(a_request(:get, 'https://files.example.com/doc.pdf')).to have_been_made.once
      end
    end

    it 'follows a redirect whose Location only needs encoding repair' do
      stub_request(:get, 'https://files.example.com/doc.pdf')
        .to_return(status: 302, headers: { 'Location' => 'https://files.example.com/my doc.pdf' })
      stub_request(:get, 'https://files.example.com/my%20doc.pdf').to_return(status: 200, body: 'pdf')

      expect(described_class.call('https://files.example.com/doc.pdf', validate: true).body).to eq('pdf')
    end

    it 'gives up after the redirect budget' do
      stub_request(:get, %r{\Ahttps://files\.example\.com/loop})
        .to_return(status: 302, headers: { 'Location' => '/loop' })

      expect { described_class.call('https://files.example.com/loop', validate: true) }
        .to raise_error(DownloadUtils::UnableToDownload, /Too many redirects/)
      expect(a_request(:get, 'https://files.example.com/loop'))
        .to have_been_made.times(DownloadUtils::MAX_REDIRECTS + 1)
    end

    it 'bounds the final body (not the redirect) when max_bytes is given' do
      stub_request(:get, 'https://files.example.com/a')
        .to_return(status: 302, headers: { 'Location' => '/b' }, body: 'x' * 50)
      stub_request(:get, 'https://files.example.com/b').to_return(body: 'y' * 20)

      expect(described_class.call('https://files.example.com/a', validate: true, max_bytes: 30).body)
        .to eq('y' * 20)

      stub_request(:get, 'https://files.example.com/b').to_return(body: 'y' * 40)

      expect { described_class.call('https://files.example.com/a', validate: true, max_bytes: 30) }
        .to raise_error(DownloadUtils::TooLarge)
    end
  end

  describe 'unvalidated internal downloads' do
    it 'keeps following redirects on localhost, unpinned, as local development relies on' do
      stub_request(:get, 'http://localhost:3000/a').to_return(status: 302, headers: { 'Location' => '/b' })
      stub_request(:get, 'http://localhost:3000/b').to_return(body: 'local')

      expect(described_class.call('http://localhost:3000/a', validate: false).body).to eq('local')
      expect(OutboundAddress).not_to have_received(:resolve)
    end
  end
end
