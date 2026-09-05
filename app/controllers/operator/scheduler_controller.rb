# frozen_string_literal: true

module Operator
  # The recurring-job clock: what is scheduled, when each job last ran, how
  # long it took, whether it worked, and what it said when it did not.
  #
  # The schedule itself is read from config/schedule.yml — the same file
  # sidekiq-cron loads — so this page cannot drift from what actually runs.
  # When Sidekiq's own registry is loaded (a running server, or a process that
  # has loaded the schedule) the cron line is read from there instead, because
  # that is the line the scheduler is really using.
  class SchedulerController < BaseController
    # The heartbeat is not a business job: it exists to prove the scheduler is
    # alive, and "run it now" would prove nothing at all.
    HEARTBEAT = 'scheduler_heartbeat'

    # Job name → job class, resolved ONCE from config/schedule.yml when this
    # class loads. A request parameter only ever picks a KEY of this map; it
    # never names a class, so nothing typed into the form can be constantized.
    RUNNABLE_JOBS = YAML.load_file(Rails.root.join('config/schedule.yml'))
                        .except(HEARTBEAT)
                        .to_h { |name, entry| [name, entry.fetch('class').constantize] }
                        .freeze

    rescue_from Refused, with: :refused

    def show
      load_schedule
    end

    # Runs a scheduled job out of turn. Always enqueued, never inline: these
    # jobs walk every account and talk to Stripe, and a web request is not
    # where that belongs. The job NAME comes from the schedule file, so no
    # request parameter can name a class to run.
    def run_now
      reason = required_reason
      name = params[:job].to_s
      entry = schedule[name]

      raise Refused, t('operator_refused_job_unknown') if entry.nil?
      raise Refused, t('operator_refused_job_heartbeat') if name == HEARTBEAT

      job_class = RUNNABLE_JOBS[name]

      raise Refused, t('operator_refused_job_unknown') if job_class.nil?

      ApplicationRecord.transaction do
        OperatorEvents.record!(operator: true_user, action: 'scheduler.run_now', reason:,
                               details: { job: name, job_class: entry['class'] }, request:)

        job_class.perform_later
      end

      redirect_to operator_scheduler_path, notice: t('operator_notice_job_enqueued', job: name)
    end

    private

    def load_schedule
      # An empty hash from SchedulerStamps.all means the stamp store could not
      # be read at all — a normal read names every job. The page says that
      # rather than painting "never run" beside every row, which during a
      # Redis incident is the opposite of the truth.
      @stamps = SchedulerStamps.all
      @stamps_unavailable = @stamps.empty?
      @cron_source = registered_crons.present? ? :sidekiq : :file
      @rows = schedule.map { |name, entry| row_for(name, entry) }
    end

    def row_for(name, entry)
      cron = registered_crons.fetch(name, entry['cron'])

      { name:, cron:, queue: entry['queue'], job_class: entry['class'], description: entry['description'],
        stamp: @stamps[name], next_run: next_run(cron), heartbeat: name == HEARTBEAT }
    end

    def schedule
      @schedule ||= YAML.load_file(Rails.root.join('config/schedule.yml')) || {}
    end

    # What sidekiq-cron actually holds right now, when anything does. An empty
    # registry is not an error — a web process that has never loaded the
    # schedule simply has none — so the page falls back to the file and says
    # which of the two it is showing.
    def registered_crons
      @registered_crons ||=
        begin
          Sidekiq::Cron::Job.all.to_h { |job| [job.name, job.cron] }
        rescue StandardError => e
          ErrorReport.error(e)

          {}
        end
    end

    # The next time this cron line fires, in UTC. A line fugit cannot parse is
    # shown as unknown rather than taking the page down.
    def next_run(cron)
      next_time = Fugit.parse_cron(cron.to_s)&.next_time

      next_time&.to_t&.utc
    rescue StandardError
      nil
    end

    def refused(error)
      flash.now[:alert] = error.message

      load_schedule

      render :show, status: :unprocessable_content
    end
  end
end
