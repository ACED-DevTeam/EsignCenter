# frozen_string_literal: true

require_relative 'test_logging'
require 'shellwords'
Rails.application.load_tasks

module TrackedSecurityGates
  def run_gate!(name, command)
    if command == 'bundle exec rubocop'
      files = IO.popen(%w[git ls-files -z], &:read).split("\0")
                .select { |path| path.match?(/\.(rb|rake|ru)\z/) || %w[Gemfile Rakefile].include?(path) }
      command = Shellwords.join(['bundle', 'exec', 'rubocop', '--force-exclusion', *files])
    end

    super
  end
end

Gates.singleton_class.prepend(TrackedSecurityGates)
Rake::Task['gates:all'].invoke
