# frozen_string_literal: true

# The private marketing page (MarketingAdmin::MailboxProof): every successful
# authentication of a login — password, Google, Apple, a finished password
# reset, a remember-me restore — wipes any proof an earlier sign-in left in
# this browser's session. The sign-in paths that qualify write a fresh one
# right after; all the others leave the session without one.
Warden::Manager.after_set_user except: :fetch do |_user, warden, options|
  MarketingAdmin::MailboxProof.forget!(warden) if options[:scope] == :user
end
