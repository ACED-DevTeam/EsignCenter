# frozen_string_literal: true

# `confirmation_code` is the account-deletion second factor (review batch 2,
# P2): a six-digit code emailed to an administrator that, with nothing else,
# schedules the destruction of their company's account. It was going into the
# production log in plain text on every attempt.
Rails.application.config.filter_parameters += %i[password token otp_attempt passw secret token _key crypt salt
                                                 certificate otp ssn file cvv cvc confirmation_code]

# Rails writes "Redirected to <url>" into the production log at INFO level,
# and two of the URLs this app redirects customers to are themselves the
# credential: Stripe's Customer Portal link signs whoever opens it into that
# customer's billing (payment method, invoices, cancellation), and a Checkout
# link is the payment page for one specific customer's subscription. Anyone
# who can read a log line — an operator, a log shipper, whatever holds the
# retention copy — could otherwise walk straight into a customer's billing
# without ever authenticating as them. The destination is replaced with
# [FILTERED]; the redirect itself is unaffected.
Rails.application.config.filter_redirect += ['billing.stripe.com', 'checkout.stripe.com']
