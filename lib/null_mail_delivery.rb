# frozen_string_literal: true

# A delivery method that drops the message. Used outside the test environment
# whenever mail must not leave the box (no resolvable SMTP config, delivery
# mode "test", demo). Unlike Mail::TestMailer it retains nothing, so a
# long-running process never accumulates every undeliverable message in memory.
# Registered as :null in config/initializers/email_delivery.rb.
class NullMailDelivery
  attr_reader :settings

  def initialize(settings = {})
    @settings = settings
  end

  def deliver!(_mail)
    nil
  end
end
