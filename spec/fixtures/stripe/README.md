# Stripe fixture provenance

The JSON event files in this directory originated as Stripe sandbox CLI captures.
Before publication, customer names, address fields, account display names and
hosted invoice/PDF links were replaced with synthetic fixture values. Invoice
links use the reserved `example.test` domain and cannot open provider records.
These files are sanitized test inputs, not byte-for-byte evidence of a Stripe run.
Their top-level `api_version` is the version Stripe used when it created that
webhook event (`2026-07-29.dahlia` for the current corpus). It is historical
payload metadata and must not be rewritten to match application code.

`StripeBilling::API_VERSION` separately pins the version used for the app's
current outbound Stripe API requests (`2026-08-26.dahlia`). The suite proves
that request header directly and proves that the inbox accepts and records the
older captured webhook version. A future API-version migration needs fresh
Stripe sandbox captures plus the billing walk; editing these fixtures by hand
is not evidence of provider behavior. Sanitize identifying fields and access
links before committing new captures, while preserving their event structure,
API version and relationships needed by the tests.
