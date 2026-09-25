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

  desc 'Read-only: list internal-account formula templates and webhook URLs this release refuses'
  # Meant for the restored copy of production during the migration rehearsal
  # (docs/operations.md section 2.3). Prints ids, template names and webhook
  # HOSTS only; exits non-zero when anything needs a decision before deploy.
  task internal_audit: :environment do
    result = ReleaseInternalAudit.call

    puts ReleaseInternalAudit.report(result)

    next unless result.findings?

    abort "\nInternal audit: #{result.formula_templates.size + result.refused_webhooks.size} finding(s) " \
          'need a decision before this release is deployed'
  end
end
