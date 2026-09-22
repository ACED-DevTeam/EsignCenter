# Local preview hygiene

Local previews must use disposable or deliberately retained local data, a mail
catcher, and synthetic accounts. Bind published ports to loopback. Never point a
preview at a customer database, live mail transport, or live payment credentials.

The development entry point is `docker-compose.dev.yml`. Production-shaped
experiments must also satisfy the current configuration guards; an old local
compose file or previously working preview is not production-readiness evidence.
See [the deployment checklist](render-deploy-checklist.md) for those guards.

Keep machine-specific instructions, account inventories and verification logs
outside the repository. Local database files, uploads, generated signing keys,
mail captures and backups belong in ignored local storage, such as
`tmp/local-production/`, and must never be committed. Preserve needed local data
before replacing or cleaning up a preview.

For billing development, use only a separately configured Stripe sandbox.
Supply credentials outside Git and confirm test mode before exercising a flow.
Do not publish provider-hosted invoice links, personal test-account details or
raw browser captures. The public Stripe fixtures are sanitized examples; they
are not credentials or evidence of a live payment.

Before publication, inspect tracked files and outgoing Git history for private
artifacts. Ignore rules alone cannot prove arbitrary source content is safe.
