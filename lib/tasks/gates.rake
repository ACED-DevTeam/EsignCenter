# frozen_string_literal: true

module Gates
  ROOT = File.expand_path('../..', __dir__)
  ACCOUNT_ONE_PATTERN = Regexp.new(['\\baccount(_id)?\\s*', '==\\s*', '1\\b'].join)
  # Whole-file, multiline-aware patterns: an unscoped EncryptedConfig lookup
  # (any finder with key: and no account scoping survives a line break), any
  # first-account query, and account-one literals in any spacing.
  ISOLATION_PATTERNS = [
    /EncryptedConfig\s*\.\s*(find_by|find_by!|exists\?|where|order)\(\s*key:/m,
    /Account\s*\.\s*order\(\s*:id\s*\)\s*\.\s*(first|take|limit)/m,
    /Account\s*\.\s*(first\b|minimum\(\s*:id\s*\))/m,
    ACCOUNT_ONE_PATTERN,
    /\.order\(\s*:account_id\s*\)/m
  ].freeze
  ALLOWLIST = [
    {
      file: 'app/controllers/search_entries_reindex_controller.rb',
      pattern: /Account\s*\.\s*(first\b|minimum\(\s*:id\s*\))/m,
      reason: 'instance-global fulltext toggle storage; becomes an operator surface in Session 2'
    }
  ].freeze
  SPEC_METADATA_PATTERN = /multitenant:\s*true/n

  module_function

  def isolation_failures
    source_failures + spec_metadata_failures
  end

  def source_failures
    source_files.flat_map do |path|
      relative_path = path.delete_prefix("#{ROOT}/")
      content = File.binread(path).force_encoding(Encoding::UTF_8).scrub

      ISOLATION_PATTERNS.filter_map do |pattern|
        match = pattern.match(content)

        next unless match
        next if allowlisted?(relative_path, pattern)

        line_number = content[0...match.begin(0)].count("\n") + 1

        "#{relative_path}:#{line_number}: #{match[0].split("\n").first.strip}"
      end
    end
  end

  def spec_metadata_failures
    spec_files.flat_map do |path|
      relative_path = path.delete_prefix("#{ROOT}/")

      next [] if relative_path == 'spec/rails_helper.rb'

      File.binread(path).each_line.with_index.filter_map do |line, index|
        next unless SPEC_METADATA_PATTERN.match?(line)

        "#{relative_path}:#{index + 1}: #{line.strip}"
      end
    end
  end

  def source_files
    Dir.glob(File.join(ROOT, '{app,lib,config}', '**', '*.{rb,rake,erb}'))
  end

  def spec_files
    Dir.glob(File.join(ROOT, 'spec', '**', '*')).select { |path| File.file?(path) }.sort
  end

  def allowlisted?(file, pattern)
    ALLOWLIST.any? { |entry| entry.fetch(:file) == file && entry.fetch(:pattern) == pattern }
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
