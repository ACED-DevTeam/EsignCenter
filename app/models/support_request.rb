# frozen_string_literal: true

# What somebody typed into /support. Deliberately NOT an ActiveRecord model:
# a support message is an email to a mailbox a person reads, and there is no
# second thing the product does with it, so there is no table, no id and
# nothing to leak later. It is an ActiveModel object purely so the form gets
# ordinary Rails validation, per-field error messages and `form_for`.
#
# Everything here is what the VISITOR typed and none of it is trusted for
# anything but its own text: who they are signed in as, which account, and
# which plan are derived on the server (SupportRequestsController), never read
# from this form.
class SupportRequest
  include ActiveModel::Model

  NAME_LIMIT = 100
  MESSAGE_MINIMUM = 20
  MESSAGE_LIMIT = 4_000

  # The value is what the mail subject and the operator's filters see; the
  # label is what the visitor picks. English-only, like the page.
  TOPICS = {
    'account' => 'Account & sign-in',
    'sending' => 'Sending & signing',
    'billing' => 'Billing',
    'api' => 'API & webhooks',
    'security' => 'Security report',
    'other' => 'Something else'
  }.freeze

  # Readers for the three that are trimmed on the way in (below), a plain
  # accessor for the one that is not.
  attr_reader :name, :email, :message
  attr_accessor :topic

  validates :name, presence: true, length: { maximum: NAME_LIMIT }
  validates :email, presence: true, format: { with: User::FULL_EMAIL_REGEXP,
                                              message: 'does not look like an email address' }
  validates :topic, inclusion: { in: TOPICS.keys, message: 'is not one of the choices' }
  validates :message, presence: true,
                      length: { minimum: MESSAGE_MINIMUM, maximum: MESSAGE_LIMIT }

  def topic_label
    TOPICS.fetch(topic, TOPICS.fetch('other'))
  end

  # Trimmed on the way in, so " " is blank and a stray newline never becomes
  # part of a mail subject.
  def name=(value)
    @name = value.to_s.strip
  end

  def email=(value)
    @email = value.to_s.strip
  end

  def message=(value)
    @message = value.to_s.strip
  end
end
