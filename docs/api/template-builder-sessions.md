# App B Template Builder Sessions

Use template builder sessions when another app needs a full CRM-style document workflow:

- open an existing EsignCenter template inside the other app;
- clone a saved template for a customer, file, or CRM record;
- replace the cloned template's document with a generated PDF while keeping field placement;
- create a new template from generated PDF/image documents;
- let the user drag fields, save the template, then send or embed signing.

The other app should call this API from its backend. Do not put the EsignCenter `X-Auth-Token` in browser code.

## Create a builder session

`POST /api/template_builder_sessions`

Headers:

```http
X-Auth-Token: ESIGNCENTER_API_TOKEN
Content-Type: application/json
```

`embed_origin` must be the exact origin that will show the builder iframe. Use HTTPS for real apps, for example `https://crm.example.com`. Local development may use `http://localhost`, `http://127.0.0.1`, or `http://[::1]`.

Choose one source mode:

```json
{
  "template_id": 456,
  "embed_origin": "https://crm.example.com"
}
```

```json
{
  "clone_template_id": 456,
  "name": "Client Closing Packet",
  "external_id": "crm-file-123",
  "embed_origin": "https://crm.example.com"
}
```

```json
{
  "clone_template_id": 456,
  "name": "Generated Closing Packet",
  "embed_origin": "https://crm.example.com",
  "documents": [
    {
      "name": "closing-packet.pdf",
      "file": "BASE64_ENCODED_PDF"
    }
  ]
}
```

```json
{
  "name": "New CRM Template",
  "external_id": "crm-template-123",
  "folder_name": "CRM Templates",
  "embed_origin": "https://crm.example.com",
  "documents": [
    {
      "name": "listing-agreement.pdf",
      "file": "BASE64_ENCODED_PDF"
    }
  ],
  "submitters": [
    {
      "name": "Client"
    }
  ]
}
```

The response includes:

```json
{
  "id": 789,
  "template_id": 789,
  "name": "Generated Closing Packet",
  "status": "ready",
  "builder_src": "https://your-instance.example.com/embed/template_builder/SIGNED_TOKEN",
  "signing_session_url": "https://your-instance.example.com/api/signing_sessions",
  "expires_at": "2026-06-07T15:00:00Z"
}
```

`builder_src` is a short-lived URL. Treat it like a bearer token: only give it to the user who is allowed to edit that template.

## Embed the builder

In a React app, load the self-hosted builder script and render the returned `builder_src`:

```jsx
import { useEffect, useRef } from 'react'

export function TemplateBuilder({ builderSession }) {
  const ref = useRef(null)

  useEffect(() => {
    const script = document.createElement('script')
    script.src = 'https://your-instance.example.com/js/builder.js'
    script.async = true
    document.head.appendChild(script)

    return () => script.remove()
  }, [])

  useEffect(() => {
    const element = ref.current
    if (!element) return

    const onSave = (event) => {
      console.log('Template saved', event.detail.template)
    }

    element.addEventListener('save', onSave)

    return () => element.removeEventListener('save', onSave)
  }, [])

  return (
    <esigncenter-builder
      ref={ref}
      data-src={builderSession.builder_src}
      data-height="900px"
    />
  )
}
```

The embedded builder sends `load`, `change`, and `save` events to the parent app. A saved template with fields returns `status: "ready"`.

## Send or sign after editing

After the template is ready, call `POST /api/signing_sessions` from the other app's backend using the returned `template_id`.

For an in-app signing portal:

```json
{
  "template_id": 789,
  "embed_origin": "https://crm.example.com",
  "send_email": false,
  "submitters": [
    {
      "role": "Client",
      "email": "client@example.com"
    }
  ]
}
```

Embed the returned `embed_src` with the MIT `@docuseal/react` signing form or the self-hosted `/js/form.js` script.

For a client email flow, set `send_email` to `true` or send the returned signer link from your app.

After signing is complete, use the existing EsignCenter webhook events or `GET /api/signing_sessions/{id}` to detect completion. Use `documents_url` from the signing session response to fetch the signed PDF back into the CRM.
