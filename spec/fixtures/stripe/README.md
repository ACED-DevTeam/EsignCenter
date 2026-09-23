# Stripe fixture provenance

The JSON event files in this directory are preserved Stripe CLI captures.
Their top-level `api_version` is the version Stripe used when it created that
webhook event (`2026-07-29.dahlia` for the current corpus). It is historical
payload metadata and must not be rewritten to match application code.

`StripeBilling::API_VERSION` separately pins the version used for the app's
current outbound Stripe API requests (`2026-08-26.dahlia`). The suite proves
that request header directly and proves that the inbox accepts and records the
older captured webhook version. A future API-version migration needs fresh
Stripe sandbox captures plus the billing walk; editing these captures by hand
is not evidence.
