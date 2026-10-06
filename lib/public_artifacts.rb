# frozen_string_literal: true

require 'open3'

# A path guard for the Git index, including files force-added past .gitignore.
# This complements secret scanning; it does not inspect or print file contents.
module PublicArtifacts
  ROOT_PATTERNS = %w[
    .env .env.* *.env *.log config/master.key
    evidence/**/* backups/**/* private-release-*/**/* plans/**/*
    db/*.sql db/*.sql.gz db/*.dump db/*.backup
    RESULTS*.txt FINAL-LOCAL-VALIDATION*.txt RELEASE-SEQUENCE*.txt
    READINESS-FOLLOWUP*.txt *-HANDOFF*.txt docs/release-readiness-*.md
    docs/launch-review-*.md docs/api-usage-tiers-verification.md
  ].freeze
  ENV_EXAMPLES = %w[.env.example .env.sample .env.*.example].freeze

  module_function

  def forbidden?(path)
    return true if path.split('/').include?('.playwright-cli')
    return false if %w[db/structure.sql db/seeds.sql].include?(path)
    return false if ENV_EXAMPLES.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME) }

    ROOT_PATTERNS.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
  end

  def tracked_failures(root = File.expand_path('..', __dir__))
    paths, status = Open3.capture2('git', 'ls-files', '-z', chdir: root)
    raise 'Cannot inspect the Git index for private artifacts' unless status.success?

    paths.split("\0").select { |path| forbidden?(path) }
  end

  def check!
    failures = tracked_failures
    raise "Private artifacts are tracked:\n#{failures.join("\n")}" if failures.any?

    puts 'Public-artifact gate passed.'
  end
end
