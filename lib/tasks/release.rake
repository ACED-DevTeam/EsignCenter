# frozen_string_literal: true

require_relative '../production_readiness'

namespace :release do
  desc 'Check dark-deploy environment names and launch switches without printing secrets'
  # Deliberately runs before Rails initializes: this task must diagnose the
  # missing values that production boot guards would otherwise stop on.
  task :preflight do # rubocop:disable Rails/RakeEnvironment
    checks = ProductionReadiness.checks

    puts 'EsignCenter dark-deploy preflight (values are never printed)'
    checks.each { |check| puts "#{check.ok ? 'PASS' : 'FAIL'}  #{check.message}" }

    failures = checks.reject(&:ok)
    next if failures.empty?

    abort "Preflight failed: #{failures.size} configuration check(s) need attention"
  end
end
