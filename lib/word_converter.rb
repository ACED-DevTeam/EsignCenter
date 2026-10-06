# frozen_string_literal: true

# Word (.docx/.doc) to PDF through a headless LibreOffice process.
#
# Every conversion runs in its own throwaway directory with its own
# LibreOffice profile, under a hard wall-clock deadline, and the process group
# is killed as a whole when that deadline passes. The converter never uses the
# shell. Concurrency across the process is capped through `with_slot`, backed
# by the same store the rate limiter uses: `max_concurrent` slot keys
# (WORD_CONVERSION_SLOTS, default 2), each taken with an atomic set-if-absent
# and released only by its holder. See docs/word-uploads.md.
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
  DEFAULT_MAX_CONCURRENT = 2
  SLOTS_ENV = 'WORD_CONVERSION_SLOTS'
  BINARY = ENV.fetch('SOFFICE_PATH', 'soffice')
  SLOT_KEY_PREFIX = 'word-conversion-slot-'
  # A crashed holder's slot frees itself when this runs out.
  ACTIVE_TTL = 10.minutes
  # A LibreOffice that dies without output this soon after starting is a cold
  # first launch (font cache build), not a bad document: retried once.
  COLD_START_SECONDS = 10
  LOG_TAIL_BYTES = 2_000
  TERM_GRACE_SECONDS = 2
  POLL_INTERVAL = 0.05

  # LibreOffice settings written into the fresh per-conversion profile before
  # it starts, so an uploaded document cannot make the server reach out:
  #
  #   * BlockUntrustedRefererLinks — refuses every link (linked images and
  #     other external resources) from a document outside the trusted
  #     locations, which an upload never is;
  #   * Writer's Content/Update/Link = 2 ("never") — linked sections and
  #     fields are not refreshed from their source while loading;
  #   * DisableActiveContent — no OLE or DDE links;
  #   * macros off, at the highest security level, belt and braces (soffice
  #     does not run document macros in a headless conversion by default).
  PROFILE_SETTINGS = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="BlockUntrustedRefererLinks" oor:op="fuse"><value>true</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="DisableActiveContent" oor:op="fuse"><value>true</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
    <item oor:path="/org.openoffice.Office.Writer/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>2</value></prop></item>
    </oor:items>
  XML

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

  # How many conversions may run at once on this instance: WORD_CONVERSION_SLOTS
  # as a whole number, never below 1. Unset or not a number means the default.
  # Read on every call, so an operator's change takes effect at the next job.
  def max_concurrent
    value = Integer(ENV.fetch(SLOTS_ENV, ''), exception: false)

    value.nil? ? DEFAULT_MAX_CONCURRENT : [value, 1].max
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

  # Holds one of `max_concurrent` conversion slots for the block. Each slot is
  # a key in RateLimit.store taken with an atomic set-if-absent (SET NX on
  # Redis, `unless_exist` on the memory store) and a TTL, so a crashed worker
  # cannot pin a slot forever and two workers can never share one — there is
  # no counter to race on. Raises Busy when every slot is taken, and when
  # the store cannot answer: the cap fails closed, the job's delayed retry
  # comes back when the store does.
  def with_slot
    key, token = acquire_slot

    yield
  ensure
    release_slot(key, token) if key
  end

  def slot_keys
    Array.new(max_concurrent) { |i| "#{SLOT_KEY_PREFIX}#{i + 1}" }
  end

  def acquire_slot
    token = SecureRandom.uuid
    keys = slot_keys
    key = keys.find { |slot_key| claim_slot(slot_key, token) }

    raise Busy, "#{keys.size} conversions already running" if key.nil?

    [key, token]
  end

  # true only when this call created the key. A store that raises or answers
  # with anything but true (RedisCacheStore's error handler returns nil)
  # counts as taken.
  def claim_slot(key, token)
    RateLimit.store.write(key, token, unless_exist: true, expires_in: ACTIVE_TTL) == true
  rescue StandardError => e
    Rails.logger.error(e)

    false
  end

  # Only the holder releases its slot: a slot whose TTL ran out and was taken
  # over by another worker carries that worker's token and is left alone.
  def release_slot(key, token)
    RateLimit.store.delete(key) if RateLimit.store.read(key) == token
  rescue StandardError => e
    Rails.logger.error(e)

    nil
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

    seed_profile(profile)

    # `unsetenv_others`: LibreOffice gets the handful of variables below and
    # nothing else. It is parsing a document a stranger uploaded, and the
    # app's own environment carries SECRET_KEY_BASE, the Stripe and Postmark
    # keys and the provisioning token — none of which a converter needs, and
    # all of which a document exploit (or a macro that somehow ran) could
    # otherwise read straight out of /proc/self/environ.
    Process.spawn(
      soffice_env(tmp),
      BINARY, '--headless', '--norestore', '--nologo', '--nolockcheck',
      "-env:UserInstallation=file://#{profile}",
      '--convert-to', 'pdf', '--outdir', tmp, input,
      pgroup: true, unsetenv_others: true, in: File::NULL, %i[out err] => [log_path, 'w']
    )
  rescue Errno::ENOENT, Errno::EACCES => e
    raise Unavailable, "#{BINARY}: #{e.message}"
  end

  # The whole environment soffice runs with. PATH so the launcher script can
  # find its own helpers, HOME and TMPDIR inside the throwaway directory (so
  # the font cache and every scratch file die with it), a UTF-8 locale, and
  # the headless rendering backend.
  def soffice_env(tmp)
    {
      'PATH' => ENV.fetch('PATH', '/usr/local/bin:/usr/bin:/bin'),
      'HOME' => tmp,
      'TMPDIR' => tmp,
      'LANG' => ENV['LANG'].presence || 'C.UTF-8',
      'LC_ALL' => ENV['LANG'].presence || 'C.UTF-8',
      'SAL_USE_VCLPLUGIN' => 'svp'
    }
  end

  def seed_profile(profile)
    user_dir = File.join(profile, 'user')

    FileUtils.mkdir_p(user_dir)
    File.write(File.join(user_dir, 'registrymodifications.xcu'), PROFILE_SETTINGS)
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
