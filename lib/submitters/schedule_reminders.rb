# frozen_string_literal: true

module Submitters
  module ScheduleReminders
    # Reminder slots configured on the SUBMITTER_REMINDERS account config, in order.
    DURATION_FIELDS = %w[first_duration second_duration third_duration].freeze

    module_function

    # Schedules the account's configured reminder emails for a submitter, measured from sent_at.
    # Safe to call more than once: each reminder job is idempotent (see
    # SendSubmitterInvitationReminderEmailJob), so duplicate scheduling never double-sends.
    def call(submitter)
      return if submitter.sent_at.blank?

      config = AccountConfigs.find_for_account(submitter.account, AccountConfig::SUBMITTER_REMINDERS)
      value = config&.value

      return unless value.is_a?(Hash)

      DURATION_FIELDS.each_with_index do |field, index|
        duration = AccountConfigs.reminder_duration(value[field])

        next if duration.blank?

        SendSubmitterInvitationReminderEmailJob.perform_at(
          submitter.sent_at + duration,
          'submitter_id' => submitter.id,
          'reminder_index' => index + 1
        )
      end
    end
  end
end
