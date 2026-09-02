# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  # infra-keep: the retry policy is unconditional in the shipped configuration (multitenant? is never true).
  retry_on StandardError, wait: 6.seconds, attempts: 5 unless Docuseal.multitenant?
end
