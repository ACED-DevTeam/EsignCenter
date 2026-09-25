# frozen_string_literal: true

RSpec.describe WordConverter do
  let(:docx) { Rails.root.join('spec/fixtures/fieldtags.docx').binread }
  let(:fixture_bin) { Rails.root.join('spec/fixtures/bin') }
  let(:slot_keys) { described_class.slot_keys }

  before do
    described_class.reset!
    RateLimit.store.clear
  end

  after do
    described_class.reset!
    RateLimit.store.clear
  end

  describe '.available?' do
    it 'finds soffice on PATH in the container' do
      expect(described_class.available?).to be(true)
    end

    it 'is false for a binary that does not exist' do
      stub_const('WordConverter::BINARY', '/nonexistent/soffice')

      expect(described_class.available?).to be(false)
    end
  end

  describe '.word?' do
    it 'accepts the two Word content types and the extensions behind a generic type' do
      expect(described_class.word?(content_type: 'application/msword', filename: 'a.bin')).to be(true)
      expect(described_class.word?(content_type: 'application/octet-stream', filename: 'a.DOCX')).to be(true)
      expect(described_class.word?(content_type: 'application/octet-stream', filename: 'a.xlsx')).to be(false)
      expect(described_class.word?(content_type: 'application/pdf', filename: 'a.docx')).to be(false)
    end
  end

  describe '.call' do
    it 'converts a .docx into a PDF with at least one page' do
      pdf = described_class.call(docx, filename: 'fieldtags.docx')

      expect(pdf).to start_with('%PDF')
      expect(HexaPDF::Document.new(io: StringIO.new(pdf)).pages.size).to be >= 1
    end

    context 'when soffice hangs' do
      stash_env 'FAKE_SOFFICE_PID_FILE'

      it 'kills the whole process group, raises TimeoutError and removes the tmpdir' do
        stub_const('WordConverter::BINARY', fixture_bin.join('fake_soffice_hang').to_s)
        stub_const('WordConverter::TIMEOUT_SECONDS', 1)

        pid_file = Tempfile.new('fake-soffice-pid')
        ENV['FAKE_SOFFICE_PID_FILE'] = pid_file.path
        # soffice no longer inherits the app's environment, so the spec hands
        # its own variable to the fake explicitly.
        allow(described_class).to receive(:soffice_env).and_wrap_original do |original, *args|
          original.call(*args).merge('FAKE_SOFFICE_PID_FILE' => pid_file.path)
        end
        tmpdirs = record_tmpdirs

        expect { described_class.call(docx, filename: 'x.docx') }.to raise_error(WordConverter::TimeoutError)

        pids = File.read(pid_file.path).split.map(&:to_i)
        expect(pids.size).to eq(2)
        expect(pids).to all(satisfy('be gone') { |pid| process_gone?(pid) })

        expect(tmpdirs).not_to be_empty
        expect(tmpdirs).to all(satisfy { |dir| !Dir.exist?(dir) })
      ensure
        pid_file&.close!
      end
    end

    context 'when soffice fails' do
      it 'raises ConversionError with the log tail and removes the tmpdir' do
        stub_const('WordConverter::BINARY', fixture_bin.join('fake_soffice_fail').to_s)
        tmpdirs = record_tmpdirs

        expect { described_class.call(docx, filename: 'x.docx') }
          .to raise_error(WordConverter::ConversionError, /cannot open document/)

        # A failure right after launch is retried once with a fresh directory.
        expect(tmpdirs.size).to eq(2)
        expect(tmpdirs).to all(satisfy { |dir| !Dir.exist?(dir) })
      end
    end

    context 'with the environment soffice runs in' do
      stash_env 'SECRET_KEY_BASE', 'STRIPE_SECRET_KEY', 'ADMIN_PROVISION_TOKEN'

      it 'passes only a minimal, explicit environment and none of the app secrets' do
        ENV['SECRET_KEY_BASE'] = 'secret-key-base-must-not-leak'
        ENV['STRIPE_SECRET_KEY'] = 'sk_test_must_not_leak'
        ENV['ADMIN_PROVISION_TOKEN'] = 'provision-token-must-not-leak'
        stub_const('WordConverter::BINARY', fixture_bin.join('fake_soffice_env').to_s)

        error = nil

        begin
          described_class.call(docx, filename: 'x.docx')
        rescue WordConverter::ConversionError => e
          error = e
        end

        names = error.message.scan(/^([A-Z_][A-Z0-9_]*)=/).flatten

        expect(names).to include('HOME', 'PATH', 'SAL_USE_VCLPLUGIN')
        expect(names - %w[HOME PATH TMPDIR LANG LC_ALL SAL_USE_VCLPLUGIN PWD SHLVL _]).to eq([])
        expect(error.message).not_to include('must-not-leak', 'must_not_leak')
      end
    end

    it 'never fetches an image a document links to on another server' do
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      requests = Queue.new
      listener = Thread.new do
        loop do
          client = server.accept
          requests << client.gets
          client.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
          client.close
        end
      rescue IOError
        nil
      end

      pdf = described_class.call(docx_linking_image("http://127.0.0.1:#{port}/probe.png"), filename: 'linked.docx')

      expect(pdf).to start_with('%PDF')
      expect(requests.size).to eq(0)
    ensure
      server&.close
      listener&.join(2)
    end

    it 'raises Unavailable when the binary is missing' do
      stub_const('WordConverter::BINARY', '/nonexistent/soffice')

      expect { described_class.call(docx, filename: 'x.docx') }.to raise_error(WordConverter::Unavailable)
    end
  end

  describe '.max_concurrent' do
    stash_env 'WORD_CONVERSION_SLOTS', clear: true

    it 'is 2 by default, with one slot key per conversion' do
      expect(described_class.max_concurrent).to eq(2)
      expect(described_class.slot_keys).to eq(%w[word-conversion-slot-1 word-conversion-slot-2])
    end

    it 'follows WORD_CONVERSION_SLOTS, never below 1, and ignores a value that is not a number' do
      ENV['WORD_CONVERSION_SLOTS'] = '3'
      expect(described_class.max_concurrent).to eq(3)
      expect(described_class.slot_keys.size).to eq(3)

      ENV['WORD_CONVERSION_SLOTS'] = '0'
      expect(described_class.max_concurrent).to eq(1)

      ENV['WORD_CONVERSION_SLOTS'] = 'two'
      expect(described_class.max_concurrent).to eq(2)
    end

    it 'lets a third conversion in when the override allows three' do
      ENV['WORD_CONVERSION_SLOTS'] = '3'

      described_class.with_slot do
        described_class.with_slot do
          expect { described_class.with_slot { nil } }.not_to raise_error

          expect { described_class.with_slot { described_class.with_slot { raise 'never reached' } } }
            .to raise_error(WordConverter::Busy, /3 conversions already running/)
        end
      end

      expect(slot_keys.filter_map { |key| RateLimit.store.read(key) }).to be_empty
    end
  end

  describe '.with_slot' do
    def held_tokens
      slot_keys.filter_map { |key| RateLimit.store.read(key) }
    end

    it 'gives each holder its own slot and refuses a third while two are held' do
      described_class.with_slot do
        described_class.with_slot do
          expect(held_tokens.size).to eq(2)
          expect(held_tokens.uniq.size).to eq(2)

          expect { described_class.with_slot { raise 'never reached' } }
            .to raise_error(WordConverter::Busy, /2 conversions already running/)

          # The refused caller took nothing and released nothing.
          expect(held_tokens.size).to eq(2)
        end

        expect(held_tokens.size).to eq(1)
      end

      expect(held_tokens).to be_empty
    end

    it 'frees the slot when the block raises' do
      expect { described_class.with_slot { raise 'boom' } }.to raise_error('boom')

      expect(held_tokens).to be_empty
    end

    # A holder whose TTL ran out mid-conversion finds its key taken over by
    # another worker: releasing must not delete that worker's slot.
    it 'never deletes a slot that carries another worker token' do
      described_class.with_slot do
        key = slot_keys.find { |slot_key| RateLimit.store.read(slot_key) }
        RateLimit.store.write(key, 'other-worker-token')
      end

      expect(held_tokens).to eq(['other-worker-token'])
    end

    it 'fails closed when the store cannot claim a slot, whether it answers nil or raises' do
      allow(RateLimit.store).to receive(:write).and_return(nil)

      expect { described_class.with_slot { raise 'never reached' } }.to raise_error(WordConverter::Busy)

      allow(RateLimit.store).to receive(:write).and_raise(StandardError, 'store down')

      expect { described_class.with_slot { raise 'never reached' } }.to raise_error(WordConverter::Busy)
      expect(held_tokens).to be_empty
    end
  end

  # Gone means signalling it fails, or it is a zombie: the orphaned child
  # keeps a zombie entry until pid 1 reaps it, and the container's pid 1 does
  # not reap.
  # A minimal .docx whose only picture is LINKED (not embedded) from `url`:
  # rendering it faithfully would mean the converter fetching that URL.
  def docx_linking_image(url)
    namespaces = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" ' \
                 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ' \
                 'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" ' \
                 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" ' \
                 'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"'
    picture = '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="probe.png"/><pic:cNvPicPr/></pic:nvPicPr>' \
              '<pic:blipFill><a:blip r:link="rIdLinked"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>' \
              '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="952500" cy="952500"/></a:xfrm>' \
              '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
    document = [
      %(<?xml version="1.0" encoding="UTF-8"?><w:document #{namespaces}><w:body>),
      '<w:p><w:r><w:t>Linked picture below</w:t></w:r></w:p><w:p><w:r><w:drawing><wp:inline>',
      '<wp:extent cx="952500" cy="952500"/><wp:docPr id="1" name="Picture 1"/><a:graphic>',
      %(<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">#{picture}),
      '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p></w:body></w:document>'
    ].join
    package_rels = 'http://schemas.openxmlformats.org/package/2006/relationships'
    office_rels = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'

    Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry('[Content_Types].xml')
      zip.write('<?xml version="1.0" encoding="UTF-8"?>' \
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' \
                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' \
                '<Default Extension="xml" ContentType="application/xml"/>' \
                '<Override PartName="/word/document.xml" ContentType="application/' \
                'vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
      zip.put_next_entry('_rels/.rels')
      main_part = %(<Relationship Id="rId1" Type="#{office_rels}/officeDocument" Target="word/document.xml"/>)
      zip.write(relationships(package_rels, main_part))
      zip.put_next_entry('word/_rels/document.xml.rels')
      linked = %(<Relationship Id="rIdLinked" Type="#{office_rels}/image" Target="#{url}" TargetMode="External"/>)
      zip.write(relationships(package_rels, linked))
      zip.put_next_entry('word/document.xml')
      zip.write(document)
    end.string
  end

  def relationships(namespace, body)
    %(<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="#{namespace}">#{body}</Relationships>)
  end

  def process_gone?(pid)
    Process.kill(0, pid)

    File.read("/proc/#{pid}/stat").split(') ').last.start_with?('Z')
  rescue Errno::ESRCH, Errno::ENOENT
    true
  end

  def record_tmpdirs
    tmpdirs = []

    allow(Dir).to receive(:mktmpdir).and_wrap_original do |original, *args, &block|
      original.call(*args) do |dir|
        tmpdirs << dir

        block.call(dir)
      end
    end

    tmpdirs
  end
end
