# frozen_string_literal: true

module Gates
  ROOT = File.expand_path('../..', __dir__)
  ACCOUNT_ONE_PATTERN = Regexp.new(['\\baccount(_id)?\\s*', '==\\s*', '1\\b'].join)
  # Whole-file, multiline-aware patterns: an unscoped EncryptedConfig or
  # AccountConfig lookup (any finder whose first argument is key:, i.e. no
  # account scoping — and it survives a line break), any first-account query,
  # and account-one literals in any spacing.
  CONFIG_FINDERS = 'find_by|find_by!|exists\?|where|order|pluck|pick|take|' \
                   'first_or_initialize|find_or_initialize_by|find_or_create_by'
  ISOLATION_PATTERNS = [
    /EncryptedConfig\s*\.\s*(#{CONFIG_FINDERS})\(\s*key:/m,
    /AccountConfig\s*\.\s*(#{CONFIG_FINDERS})\(\s*key:/m,
    /Account\s*\.\s*order\(\s*:id\s*\)\s*\.\s*(first|take|limit)/m,
    /Account\s*\.\s*(first\b|minimum\(\s*:id\s*\))/m,
    ACCOUNT_ONE_PATTERN,
    /\.order\(\s*:account_id\s*\)/m
  ].freeze
  # Allowlist entries pin a file AND the exact matched snippet, so allowlisting
  # one known-good line never blanket-exempts the rest of the file.
  ALLOWLIST = [].freeze
  SPEC_METADATA_PATTERNS = [
    /multitenant:\s*true/n,
    /receive\(\s*:multitenant\?\s*\)\s*\.\s*and_return\(\s*true\s*\)/n
  ].freeze
  # Stubbing multitenancy on is banned outright in the golden specs: they must
  # exercise the shipped single-tenant configuration.
  GOLDEN_SPEC_PREFIX = 'spec/golden/'
  # This file is the gate definition: it necessarily spells out every banned
  # pattern and every allowlisted snippet, so it never scans itself.
  SELF_PATH = 'lib/tasks/gates.rake'

  module_function

  def isolation_failures
    source_failures + spec_metadata_failures
  end

  def source_failures
    source_files.flat_map do |path|
      relative_path = path.delete_prefix("#{ROOT}/")
      content = File.binread(path).force_encoding(Encoding::UTF_8).scrub
      lines = content.lines

      # Every occurrence is reported, not just the first: a file with one
      # allowlisted line must still fail on a second, unreviewed one.
      ISOLATION_PATTERNS.flat_map do |pattern|
        content.to_enum(:scan, pattern).filter_map do
          line_number = content[0...Regexp.last_match.begin(0)].count("\n") + 1
          line = lines[line_number - 1].to_s.strip

          next if allowlisted?(relative_path, line)

          "#{relative_path}:#{line_number}: #{line}"
        end
      end
    end
  end

  def spec_metadata_failures
    spec_files.flat_map do |path|
      relative_path = path.delete_prefix("#{ROOT}/")

      next [] if relative_path == 'spec/rails_helper.rb'

      patterns = spec_metadata_patterns_for(relative_path)

      File.binread(path).each_line.with_index.filter_map do |line, index|
        next unless patterns.any? { |pattern| pattern.match?(line) }

        "#{relative_path}:#{index + 1}: #{line.strip}"
      end
    end
  end

  def spec_metadata_patterns_for(relative_path)
    return SPEC_METADATA_PATTERNS if relative_path.start_with?(GOLDEN_SPEC_PREFIX)

    SPEC_METADATA_PATTERNS.first(1)
  end

  def source_files
    Dir.glob(File.join(ROOT, '{app,lib,config}', '**', '*.{rb,rake,erb}'))
       .reject { |path| path.delete_prefix("#{ROOT}/") == SELF_PATH }
  end

  def spec_files
    Dir.glob(File.join(ROOT, 'spec', '**', '*')).select { |path| File.file?(path) }.sort
  end

  # An entry exempts one reviewed line, never the whole file: the matched
  # line itself has to carry the allowlisted snippet.
  def allowlisted?(file, line)
    ALLOWLIST.any? { |entry| entry.fetch(:file) == file && line.include?(entry.fetch(:snippet)) }
  end

  def run_gate!(name, command)
    Rake::FileUtilsExt.sh(command)
  rescue RuntimeError
    abort "#{name} failed"
  end
end

namespace :gates do
  desc 'Reject tenant-isolation leak patterns and banned spec metadata'
  task isolation: :environment do
    failures = Gates.isolation_failures

    abort "Isolation gate failed:\n#{failures.join("\n")}" if failures.any?

    puts 'Isolation gate passed.'
  end

  desc 'Placeholder for the Session 3 branding gate'
  task branding: :environment do
    puts 'branding gate lands in Session 3'
  end

  desc 'Run all CI gates'
  task all: :environment do
    Rake::Task['gates:isolation'].invoke
    Gates.run_gate!('Rubocop gate', 'bundle exec rubocop')
    Gates.run_gate!('ERB lint gate', 'bundle exec erb_lint ./app')
    Gates.run_gate!('ESLint gate', './node_modules/eslint/bin/eslint.js "app/javascript/**/*.js"')
    Gates.run_gate!('Brakeman gate', 'bundle exec brakeman -q --exit-on-warn')
  end
end
