# frozen_string_literal: true

# Word (.docx/.doc) to PDF through a headless LibreOffice process.
#
# Every conversion runs in its own throwaway directory with its own
# LibreOffice profile, under a hard wall-clock deadline, and the process group
# is killed as a whole when that deadline passes. The converter never uses the
# shell. Concurrency across the process is capped through `with_slot`, backed
# by the same store the rate limiter uses. See docs/word-uploads.md.
module WordConverter
  EXTENSIONS = %w[.docx .doc].freeze
  CONTENT_TYPES = {
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => '.docx',
    'application/msword' => '.doc'
  }.freeze
  # Content types a sniffer returns when it cannot tell what a file is; the
  # extension decides for those (a .docx is a zip, a .doc is an OLE container).
  GENERIC_CONTENT_TYPES = %w[
    application/octet-stream
    binary/octet-stream
    application/zip
    application/x-zip-compressed
    application/x-ole-storage
  ].freeze
  MAX_FILE_SIZE = 20.megabytes
  TIMEOUT_SECONDS = 120
  MAX_CONCURRENT = 2
  BINARY = ENV.fetch('SOFFICE_PATH', 'soffice')
  ACTIVE_KEY = 'word-conversion-active'
  ACTIVE_TTL = 10.minutes
  # A LibreOffice that dies without output this soon after starting is a cold
  # first launch (font cache build), not a bad document: retried once.
  COLD_START_SECONDS = 10
  LOG_TAIL_BYTES = 2_000
  TERM_GRACE_SECONDS = 2
  POLL_INTERVAL = 0.05

  Error = Class.new(StandardError)
  TimeoutError = Class.new(Error)
  ConversionError = Class.new(Error)
  Busy = Class.new(Error)
  FileTooLarge = Class.new(Error)
  Unavailable = Class.new(Error)
  ColdStartFailure = Class.new(Error)
  private_constant :ColdStartFailure

  module_function

  # Memoized per process; `reset!` forgets the answer (specs, or after the
  # binary is installed while the app runs).
  def available?
    return @available unless @available.nil?

    @available = resolve_binary.present?
  end

  def reset!
    @available = nil
  end

  def enabled?
    ENV['WORD_CONVERSION_ENABLED'] != 'false' && available?
  end

  def word?(content_type:, filename:)
    return true if CONTENT_TYPES.key?(content_type.to_s)

    generic_content_type?(content_type) && EXTENSIONS.include?(File.extname(filename.to_s).downcase)
  end

  def generic_content_type?(content_type)
    content_type.blank? || GENERIC_CONTENT_TYPES.include?(content_type.to_s)
  end

  # Word bytes (a String or an IO) in, PDF bytes out. Raises TimeoutError,
  # ConversionError or Unavailable.
  def call(io, filename:)
    data = io.respond_to?(:read) ? io.read : io.to_s
    attempts = 0

    begin
      attempts += 1

      convert(data, filename:)
    rescue ColdStartFailure => e
      retry if attempts < 2

      raise ConversionError, e.message
    end
  end

  # Holds one of MAX_CONCURRENT conversion slots for the block. The counter
  # lives in RateLimit.store with a TTL, so a crashed worker cannot pin a slot
  # forever. Raises Busy when every slot is taken — and when the store cannot
  # answer (a nil increment): the cap fails closed, the job's delayed retry
  # comes back when the store does.
  def with_slot
    active = RateLimit.store.increment(ACTIVE_KEY, 1, expires_in: ACTIVE_TTL)

    raise Busy, 'conversion slot counter unavailable' if active.nil?

    if active > MAX_CONCURRENT
      release_slot

      raise Busy, "#{active - 1} conversions already running"
    end

    acquired = true

    yield
  ensure
    release_slot if acquired
  end

  # A counter at or below zero is deleted rather than kept: a stale key would
  # otherwise drift negative (a decrement after the TTL expired recreates it
  # below zero and widens the cap), and a fresh key gets a fresh TTL.
  def release_slot
    left = RateLimit.store.decrement(ACTIVE_KEY, 1)

    RateLimit.store.delete(ACTIVE_KEY) if left && left <= 0
  end

  def convert(data, filename:)
    Dir.mktmpdir('word-conversion') do |tmp|
      input = File.join(tmp, "in#{input_extension(filename)}")
      output = File.join(tmp, 'in.pdf')
      log_path = File.join(tmp, 'soffice.log')

      File.binwrite(input, data)

      started_at = monotonic_now
      pid = spawn_soffice(tmp, input, log_path)
      status = wait_with_deadline(pid)
      elapsed = monotonic_now - started_at

      unless status.success? && File.exist?(output)
        message = "soffice exited with #{status.exitstatus.inspect}: #{log_tail(log_path)}"

        raise ColdStartFailure, message if !File.exist?(output) && elapsed < COLD_START_SECONDS

        raise ConversionError, message
      end

      pdf = File.binread(output)

      raise ConversionError, "soffice output is not a PDF: #{log_tail(log_path)}" unless pdf.start_with?('%PDF')

      pdf
    end
  end

  def spawn_soffice(tmp, input, log_path)
    profile = File.join(tmp, 'profile')

    Process.spawn(
      { 'HOME' => tmp, 'SAL_USE_VCLPLUGIN' => 'svp' },
      BINARY, '--headless', '--norestore', '--nologo', '--nolockcheck',
      "-env:UserInstallation=file://#{profile}",
      '--convert-to', 'pdf', '--outdir', tmp, input,
      pgroup: true, in: File::NULL, %i[out err] => [log_path, 'w']
    )
  rescue Errno::ENOENT, Errno::EACCES => e
    raise Unavailable, "#{BINARY}: #{e.message}"
  end

  def wait_with_deadline(pid)
    deadline = monotonic_now + TIMEOUT_SECONDS

    loop do
      _, status = Process.wait2(pid, Process::WNOHANG)

      return status if status

      if monotonic_now > deadline
        kill_process_group(pid)

        raise TimeoutError, "soffice did not finish within #{TIMEOUT_SECONDS} seconds"
      end

      sleep POLL_INTERVAL
    end
  end

  # TERM the whole group, give it the grace period, then KILL the group —
  # always, even when the leader is already gone: a descendant that ignored
  # TERM is still in the group. Both signals are ESRCH-safe, and the leader
  # is reaped so nothing is left behind as a zombie.
  def kill_process_group(pid)
    signal_group(pid, 'TERM')

    grace_deadline = monotonic_now + TERM_GRACE_SECONDS
    leader_reaped = false

    while monotonic_now < grace_deadline
      leader_reaped ||= reap_nonblocking(pid)

      break if leader_reaped && group_gone?(pid)

      sleep POLL_INTERVAL
    end

    signal_group(pid, 'KILL')

    reap(pid) unless leader_reaped
  end

  def signal_group(pid, signal)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def group_gone?(pid)
    Process.kill(0, -pid)

    false
  rescue Errno::ESRCH
    true
  rescue Errno::EPERM
    false
  end

  def reap_nonblocking(pid)
    _, status = Process.wait2(pid, Process::WNOHANG)

    !status.nil?
  rescue Errno::ECHILD
    true
  end

  def reap(pid)
    Process.wait(pid)
  rescue Errno::ECHILD
    nil
  end

  def input_extension(filename)
    ext = File.extname(filename.to_s).downcase

    EXTENSIONS.include?(ext) ? ext : EXTENSIONS.first
  end

  def log_tail(log_path)
    return '' unless File.exist?(log_path)

    size = File.size(log_path)

    File.open(log_path, 'rb') do |f|
      f.seek([size - LOG_TAIL_BYTES, 0].max)
      f.read.to_s.scrub.strip
    end
  end

  def resolve_binary
    return executable?(BINARY) ? BINARY : nil if BINARY.include?(File::SEPARATOR)

    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |dir|
      candidate = File.join(dir, BINARY)

      return candidate if executable?(candidate)
    end

    nil
  end

  def executable?(path)
    File.file?(path) && File.executable?(path)
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
