# App B Template Preview Sessions

Use template preview sessions when another app needs to show what a template's signing form looks like — before anyone is invited to sign:

- a "preview this document" button next to a template in the other app's UI;
- a read-only sample of the packet a customer is about to receive;
- a check that a generated PDF's fields landed where they should, with sample data painted in.

A preview session creates no submission or submitter and does not change the template. Ordinary API activity tracking still applies. The returned URL carries a short-lived signed token that holds everything the preview page needs, and the page it opens cannot be submitted.

The other app should call this API from its backend. Do not put the EsignCenter `X-Auth-Token` in browser code.

## Create a preview session

`POST /api/template_preview_sessions`

Headers:

```http
X-Auth-Token: ESIGNCENTER_API_TOKEN
Content-Type: application/json
```

```json
{
  "template_id": 456,
  "embed_origin": "https://crm.example.com"
}
```

`embed_origin` must be the exact origin that will show the preview iframe. Use HTTPS for real apps, for example `https://crm.example.com`. Local development may use `http://localhost`, `http://127.0.0.1`, or `http://[::1]`.

Optionally paint sample data into the form with `values`, keyed by the template field's `uuid`:

```json
{
  "template_id": 456,
  "embed_origin": "https://crm.example.com",
  "values": {
    "8e2ab0a4-7d0f-4c6a-9f1a-6a1a5a2f0b11": "Jamie Borrower",
    "b1d0f7c2-5e35-4a05-9d2c-0f0f2b4b91f3": "2026-09-01"
  },
  "expires_in_minutes": 60
}
```

- `values` — optional. String keys, string values. At most 200 entries and 4 KB of JSON in total (the whole token has to fit in a URL). These are display-only; nothing is saved against the template.
- `expires_in_minutes` — optional. Defaults to 2 hours, capped at 24 hours.

### What `values` can address

Each key may be a field's `uuid` **or** the field's `name`. Keys that match no field in the template are ignored.

Sample data only makes sense for fields that display as plain text, so values are accepted for these field types:

`text`, `number`, `date`, `select`, `radio`, `checkbox`, `cells`, `phone`

Values aimed at a field whose real value is an uploaded file — `signature`, `initials`, `image`, `file`, `stamp`, `payment`, `verification` — are ignored, because there is no such upload in a preview. Sending them is harmless: the page still renders, that one field is simply left blank.

The response:

```json
{
  "id": "SIGNED_TOKEN",
  "token": "SIGNED_TOKEN",
  "template_id": 456,
  "name": "Client Closing Packet",
  "preview_src": "https://your-instance.example.com/embed/template_preview/SIGNED_TOKEN",
  "embed_origin": "https://crm.example.com",
  "expires_at": "2026-06-07T15:00:00Z"
}
```

A template that belongs to another account returns `404 Template not found`. So does a template that was only *shared* into your account from a linked or testing account — previews are minted only for templates your own account owns.

## Embed the preview

`preview_src` is a plain URL — put it in an iframe:

```jsx
export function TemplatePreview({ previewSession }) {
  return (
    <iframe
      src={previewSession.preview_src}
      style={{ width: '100%', height: '900px', border: 0 }}
      title="Document preview"
    />
  )
}
```

The preview page allows framing only from the `embed_origin` the session was minted for, and only until the token expires. An expired, tampered or unknown token renders `404 Not found`.

`preview_src` is a short-lived bearer URL for one template. Give it only to a user who is allowed to see that template's contents.

## What the preview page is not

- It cannot be signed or submitted — the form is rendered in dry-run mode.
- It does not count as a form view and fires no webhook events.
- It carries no link into the EsignCenter app's own screens; the viewer never needs an EsignCenter login.
- It goes nowhere. A preview viewer is a guest of your app, so the page is stripped of every destination the real signing form would carry: the template's "redirect after completion" URL, the account's completed-button link and completed message, and the account's policy links. Configure those all you like — the real signing form still uses them, the preview never shows them.

When you actually need a signable link, use `POST /api/signing_sessions` instead — see [signing-sessions.md](signing-sessions.md).

## Standalone account rules

Internal accounts provisioned by a connected application do not need a subscription or a human login. Customer accounts require the embedding entitlement. Preview creation, viewing, and the token-scoped document PDF stop working when the account is archived or suspended; existing preview links also stop working after a customer downgrades.

The consent disclosure uses the preview token's `/document` link, so its PDF can open without a sender account. This remains a dry run: it creates no submission, signer, or consent record. Use synthetic preview values; signed tokens are readable and the URL can appear in browser history.
