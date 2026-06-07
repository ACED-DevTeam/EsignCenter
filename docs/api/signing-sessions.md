# App A Signing Sessions

Use signing sessions when another app has already generated a final PDF and only needs DocuSeal to collect a signature and date in fixed places.

The other app should call this API from its backend. Do not put the DocuSeal `X-Auth-Token` in browser code.

## Create a signing session

`POST /api/signing_sessions`

Headers:

```http
X-Auth-Token: DOCUSEAL_API_TOKEN
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
  "embed_src": "https://docuseal.example.com/s/submitter_slug",
  "documents_url": "https://docuseal.example.com/api/submissions/123/documents",
  "status_url": "https://docuseal.example.com/api/signing_sessions/123"
}
```

## Embed in React

Application A can use the MIT `@docuseal/react` package and point it at this self-hosted DocuSeal app:

```jsx
import { DocusealForm } from '@docuseal/react'

export function SigningScreen({ signingSession }) {
  return (
    <DocusealForm
      host="docuseal.example.com"
      src={signingSession.embed_src}
      onComplete={(event) => {
        console.log('Signing completed', event.submitter.completed_at)
      }}
    />
  )
}
```

The completion event includes fresh `submitter` data and a `signing_session` status object. The signed document can be fetched from `documents_url` after the session status is `completed`. The existing DocuSeal webhook settings can also notify your app when `form.completed` or `submission.completed` happens.

## Existing templates

If the document is already a saved DocuSeal template, send `template_id` instead of `documents` and `fields`:

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
