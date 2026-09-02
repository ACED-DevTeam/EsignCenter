# frozen_string_literal: true

RSpec.describe WordConverter do
  let(:docx) { Rails.root.join('spec/fixtures/fieldtags.docx').binread }
  let(:fixture_bin) { Rails.root.join('spec/fixtures/bin') }
  let(:active_key) { described_class::ACTIVE_KEY }

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

    it 'raises Unavailable when the binary is missing' do
      stub_const('WordConverter::BINARY', '/nonexistent/soffice')

      expect { described_class.call(docx, filename: 'x.docx') }.to raise_error(WordConverter::Unavailable)
    end
  end

  describe '.with_slot' do
    it 'raises Busy beyond MAX_CONCURRENT and leaves the counter where it was' do
      described_class::MAX_CONCURRENT.times { RateLimit.store.increment(active_key, 1) }

      expect { described_class.with_slot { raise 'never reached' } }.to raise_error(WordConverter::Busy)
      expect(RateLimit.store.read(active_key)).to eq(described_class::MAX_CONCURRENT)
    end

    it 'holds a slot for the block and frees it afterwards, also when the block raises' do
      described_class.with_slot do
        expect(RateLimit.store.read(active_key)).to eq(1)
      end

      # A released last slot deletes the key (a fresh key gets a fresh TTL).
      expect(RateLimit.store.read(active_key)).to be_nil

      expect { described_class.with_slot { raise 'boom' } }.to raise_error('boom')
      expect(RateLimit.store.read(active_key)).to be_nil
    end

    it 'never leaves the counter at or below zero, whatever it found' do
      RateLimit.store.write(active_key, 0)

      described_class.with_slot do
        expect(RateLimit.store.read(active_key)).to eq(1)
      end

      expect(RateLimit.store.read(active_key)).to be_nil

      # A stale key that drifted negative (decrement after the TTL expired).
      RateLimit.store.write(active_key, -1)

      described_class.with_slot do
        expect(RateLimit.store.read(active_key)).to eq(0)
      end

      expect(RateLimit.store.read(active_key)).to be_nil
    end

    it 'fails closed when the store cannot count (nil increment) and touches nothing' do
      allow(RateLimit.store).to receive(:increment).and_return(nil)
      allow(RateLimit.store).to receive(:decrement).and_call_original

      expect { described_class.with_slot { raise 'never reached' } }
        .to raise_error(WordConverter::Busy, /unavailable/)

      expect(RateLimit.store).not_to have_received(:decrement)
      expect(RateLimit.store.read(active_key)).to be_nil
    end
  end

  # Gone means signalling it fails, or it is a zombie: the orphaned child
  # keeps a zombie entry until pid 1 reaps it, and the container's pid 1 does
  # not reap.
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
