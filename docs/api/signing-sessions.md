# App A Signing Sessions

Use signing sessions when another app has already generated a final PDF and only needs EsignCenter to collect a signature and date in fixed places.

The other app should call this API from its backend. Do not put the EsignCenter `X-Auth-Token` in browser code.

## Create a signing session

`POST /api/signing_sessions`

Headers:

```http
X-Auth-Token: ESIGNCENTER_API_TOKEN
Content-Type: application/json
```

Example body:

```json
{
  "name": "Application A Disclosure",
  "external_id": "app-a-workflow-123",
  "embed_origin": "https://app-a.example.com",
  "documents": [
    {
      "name": "disclosure.pdf",
      "file": "BASE64_ENCODED_PDF"
    }
  ],
  "submitters": [
    {
      "name": "Borrower",
      "email": "borrower@example.com",
      "external_id": "borrower-123"
    }
  ],
  "fields": [
    {
      "name": "Borrower Signature",
      "type": "signature",
      "role": "Borrower",
      "areas": [{ "x": 0.1, "y": 0.8, "w": 0.3, "h": 0.06, "page": 0, "document": 0 }]
    },
    {
      "name": "Signed Date",
      "type": "date",
      "role": "Borrower",
      "readonly": true,
      "default_value": "{{date}}",
      "areas": [{ "x": 0.72, "y": 0.8, "w": 0.18, "h": 0.04, "page": 0, "document": 0 }]
    }
  ]
}
```

Coordinates are percentages from `0` to `1` relative to the page. For example, `x: 0.1` means 10% from the left side of the page.

`embed_origin` must be the exact origin that will show the signing iframe. Use HTTPS for real apps, for example `https://app-a.example.com`. Local development may use `http://localhost`, `http://127.0.0.1`, or `http://[::1]`.

This origin is what allows the signing page to be framed only by your app.

The response includes:

```json
{
  "id": 123,
  "submission_id": 123,
  "template_id": 456,
  "status": "pending",
  "embed_src": "https://your-instance.example.com/s/submitter_slug",
  "documents_url": "https://your-instance.example.com/api/submissions/123/documents",
  "status_url": "https://your-instance.example.com/api/signing_sessions/123"
}
```

## Embed in React

Application A can use the MIT `@docuseal/react` package and point it at this self-hosted EsignCenter app:

```jsx
import { EsigncenterForm } from '@docuseal/react'

export function SigningScreen({ signingSession }) {
  return (
    <EsigncenterForm
      host="your-instance.example.com"
      src={signingSession.embed_src}
      onComplete={(event) => {
        console.log('Signing completed', event.submitter.completed_at)
      }}
    />
  )
}
```

The completion event includes fresh `submitter` data and a `signing_session` status object. The signed document can be fetched from `documents_url` after the session status is `completed`. The existing EsignCenter webhook settings can also notify your app when `form.completed` or `submission.completed` happens.

## Signer consent

Before a signer can finish, the signing form shows an electronic-signature consent checkbox ("I agree to use electronic records and signatures.") with a link to the disclosure; the Next/Complete buttons stay disabled until it is ticked. The checkbox sits above the form's buttons, so allow for one extra row when you size the iframe. The agreement is recorded as an `esign_consent` event on the submitter (the disclosure version and locale the signer saw, and a SHA-256 of that disclosure text) and printed in the audit trail.

If you create a submitter with `completed: true`, no ESIGN consent is collected or recorded — your application is responsible for the signer's consent; the audit trail marks this completion as made via API.

## Existing templates

If the document is already a saved EsignCenter template, send `template_id` instead of `documents` and `fields`:

```json
{
  "template_id": 456,
  "embed_origin": "https://app-a.example.com",
  "submitters": [
    {
      "role": "First Party",
      "email": "borrower@example.com"
    }
  ]
}
```
