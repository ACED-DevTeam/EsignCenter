# frozen_string_literal: true

# Capybara waits for the BROWSER; nothing waits for the SERVER. An example that
# clicks a button and then reads the database (or Sidekiq's queue) is asking
# about work the browser has only just been told to start — `click_button`
# returns as soon as the click is dispatched, not when the response is back.
# That race is the whole story behind the webhook-settings flakes that have
# reddened the suite since Session 5.
#
# Where the page shows the outcome, wait for the page: that is a real
# assertion. Where it does not — a request answered `head :ok` — this gives
# the same patience Capybara gives the DOM: re-read until the expectation
# holds or the wait time runs out, then let it fail with its own message.
module Eventually
  def eventually(seconds = Capybara.default_max_wait_time)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds

    begin
      yield
    rescue RSpec::Expectations::ExpectationNotMetError
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
      retry
    end
  end
end

RSpec.configure { |config| config.include Eventually, type: :system }
