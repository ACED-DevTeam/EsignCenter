# Self‑Hosted E‑Signing API — Integration Guide

This guide explains how to add e‑signing to your own apps (e.g. a VA‑claims app and a
mortgage app) using **your own self‑hosted EsignCenter**, with **no per‑document fees**.

> **Important context:** The REST API is part of the open‑source DocuSeal code this fork
> (EsignCenter) is built on — it is **not** a paid feature. The per‑document price you may
> have seen applies only to DocuSeal's hosted cloud service. When you run this
> app on your own server, the API is free and unlimited.
>
> This repository adds one capability the open‑source app was missing: creating a
> signable template **from a PDF your app generates**, through the API
> (`POST /api/templates`). Everything else below already existed in the open‑source app.

---

## 1. The big picture

Signing a document is always two steps:

1. **Template** — a document plus the positions of the fields to fill/sign.
2. **Submission** — sending that template to one or more people to actually sign.

There are two ways your apps will get a template:

| Your situation | What to do |
| --- | --- |
| **Standard forms** you reuse (same VA form, same disclosure, just different data) | Build the template **once** in the EsignCenter web app, then only create *submissions* from it via the API. |
| **One‑off PDFs** your app generates on the fly | Send the generated PDF to `POST /api/templates`, get a template back, then create a submission from it. |

Both paths end the same way: the signer gets a link (by email or one you embed), signs,
and you receive the finished, legally‑signed PDF.

---

## 2. Get your API token (one‑time)

1. Open your self‑hosted EsignCenter in a browser and sign in.
2. Go to **Settings → API**.
3. Copy the **API token** (a long secret string). Click to regenerate if you ever need to.

**Keep this token secret.** It is like a password for your whole account.

### Security model (read this)

- Call the API **server‑to‑server**: your app's **backend** holds the token and talks to
  EsignCenter. **Never** put the token in a browser, mobile app, or any client‑side code.
- Store the token in your app's environment variables / secret manager, e.g.
  `ESIGNCENTER_API_TOKEN` and `ESIGNCENTER_BASE_URL=https://your-instance.example.com`.
- Always send it in the **`X-Auth-Token`** request header (never in the URL).
- Use HTTPS for your EsignCenter server.

---

## 3. Create a template from a generated PDF — `POST /api/templates`

This is the new endpoint. Your app generates a PDF, base64‑encodes it, and posts it.
EsignCenter turns it into a reusable, signable template.

### Request

```
POST {ESIGNCENTER_BASE_URL}/api/templates
X-Auth-Token: {ESIGNCENTER_API_TOKEN}
Content-Type: application/json
```

```jsonc
{
  "name": "VA Form 21-526EZ — John Doe",          // optional; defaults to the file name
  "external_id": "crm-record-1042",                  // optional; your own reference id
  "folder_name": "Contracts",                      // optional; groups templates in the UI

  "documents": [                                    // required; 1–20 documents
    { "name": "claim", "file": "<base64 of the PDF>" }
  ],

  "submitters": [                                   // optional; the signing parties ("roles")
    { "name": "Veteran" },                          // names must be unique
    { "name": "Witness" }
  ],

  "fields": [                                        // optional; where to place fields
    {
      "name": "Veteran Signature",
      "type": "signature",                          // see field types below
      "role": "Veteran",                            // which submitter signs this
      "required": true,
      "areas": [
        { "x": 0.10, "y": 0.80, "w": 0.30, "h": 0.05, "page": 0, "document": 0 }
      ]
    }
  ]
}
```

### Two ways fields get added

- **Automatic (no `fields` in the request):** if your generated PDF already contains
  fillable form fields (many official VA and mortgage PDFs do), EsignCenter detects them
  automatically. You don't need to send `fields` at all.
- **Explicit (you send `fields`):** for plain PDFs with no built‑in fields, tell EsignCenter
  exactly where each field goes using `areas` (see coordinates below). When you send
  `fields`, automatic detection is skipped and your placement is used as‑is.

You can also create the template now and add fields later with `PUT /api/templates/{id}`,
or by opening it in the web editor.

### Coordinates

`x`, `y`, `w`, `h` are **fractions of the page** between `0` and `1` (not pixels):

- `x`, `y` = top‑left corner of the box (`0,0` is the top‑left of the page).
- `w`, `h` = width and height of the box.
- `page` = page number, starting at **0** (the first page is `0`).
- `document` = which uploaded document, starting at **0** (use this only if you upload
  more than one document in the same request).

### Field types

`text`, `date`, `checkbox`, `radio`, `signature`, `number`, `multiple`, `select`,
`initials`, `image`, `file`, `stamp`, `cells`, `phone`, `payment`.

For **`radio`** and **`multiple`** (choose‑one / choose‑many), provide `options` and give
**one area per option**, each pointing at its option with `option` (the option's value, or
its 0‑based index):

```jsonc
{
  "name": "Marital status",
  "type": "radio",
  "role": "Veteran",
  "options": [{ "value": "Single" }, { "value": "Married" }],
  "areas": [
    { "x": 0.10, "y": 0.40, "w": 0.03, "h": 0.03, "page": 0, "option": "Single" },
    { "x": 0.10, "y": 0.45, "w": 0.03, "h": 0.03, "page": 0, "option": "Married" }
  ]
}
```

### Response (`200 OK`)

You get back the full template, including each document's `id`, `uuid`, a temporary
`url` to the file, and a `preview_image_url`. Save the template `id` — you need it to send
the document for signing.

### Limits & rules

- **File types:** PDF and images only. Word/Excel/HTML are **not** accepted by this
  endpoint yet (you'll get a clear error) — see "What's not included" below.
- **Size:** up to **25 MB per document** and **20 documents** per request.
- **Rate limit:** up to **300 template creations per minute** per account (a safety
  backstop; tune `CREATE_RATE_LIMIT` in `app/controllers/api/templates_controller.rb`
  if you ever need more).
- **Account isolation:** templates are always created under the account that owns the API
  token. Tokens cannot reach another account's data.

### Errors

| Status | Meaning |
| --- | --- |
| `401` | Missing/invalid API token (`{ "error": "Not authenticated" }`). |
| `422` | Invalid input, unsupported file type, password‑protected PDF, or too large. The `error` message explains what to fix. |
| `403` | Not allowed (e.g. using a test token against production data). |
| `429` | Too many requests — slow down. |

---

## 4. Send the document for signing — `POST /api/submissions`

This endpoint is built in (inherited from DocuSeal). Once you have a template `id`, create a
submission to invite signers and pre‑fill values.

```
POST {ESIGNCENTER_BASE_URL}/api/submissions
X-Auth-Token: {ESIGNCENTER_API_TOKEN}
Content-Type: application/json
```

```jsonc
{
  "template_id": 1042,
  "send_email": true,                  // EsignCenter emails the signer a link
  "submitters": [
    {
      "role": "Veteran",
      "email": "john.doe@example.com",
      "values": {                       // pre-fill any fields by name
        "Veteran Signature": "",
        "Date": "2026-06-06"
      }
    }
  ]
}
```

The response includes each submitter with a `slug`; the signing link is
`{ESIGNCENTER_BASE_URL}/s/{slug}`. If you prefer to **embed** signing inside your own app
instead of emailing, set `send_email: false` and open that link in your UI.

See the language‑specific examples in [`docs/api/`](.) (Ruby, Python, Node, PHP, Go,
Java, C#, JavaScript, TypeScript, Shell) for the full submissions/submitters reference.

---

## 5. Get the signed document back

Two options:

- **Webhook (recommended):** in **Settings → Webhooks**, add your app's URL. EsignCenter
  POSTs a `submission.completed` event with links to the signed PDF when everyone signs.
- **Polling:** `GET /api/submissions/{id}/documents` returns links to the signed files.

---

## 6. End‑to‑end example (generated PDF → signed)

```bash
BASE="https://your-instance.example.com"
TOKEN="your-secret-api-token"

# 1) Create a template from a PDF your app generated
TEMPLATE_ID=$(curl -s -X POST "$BASE/api/templates" \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d "{
        \"name\": \"Disclosure — Jane Smith\",
        \"documents\": [{ \"name\": \"disclosure\", \"file\": \"$(base64 -i disclosure.pdf)\" }],
        \"submitters\": [{ \"name\": \"Borrower\" }],
        \"fields\": [
          { \"name\": \"Signature\", \"type\": \"signature\", \"role\": \"Borrower\",
            \"areas\": [{ \"x\": 0.1, \"y\": 0.85, \"w\": 0.3, \"h\": 0.05, \"page\": 0 }] }
        ]
      }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# 2) Send it for signing
curl -s -X POST "$BASE/api/submissions" \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d "{
        \"template_id\": $TEMPLATE_ID,
        \"send_email\": true,
        \"submitters\": [{ \"role\": \"Borrower\", \"email\": \"jane@example.com\" }]
      }"

# 3) Receive the signed PDF via your webhook (submission.completed),
#    or GET /api/submissions/{id}/documents
```

---

## 7. What's NOT included (future work)

- **Word/Excel/HTML → signable template via API.** This open‑source app can only turn
  **PDFs and images** into templates programmatically. Turning a `.docx` or raw HTML into
  a PDF first requires a converter (e.g. LibreOffice) that isn't bundled here. If your apps
  generate Word/HTML, convert to PDF on your side first, then call `POST /api/templates`.
- **Remote file URLs.** This endpoint takes the file as base64 in the request on purpose.
  Fetching a document from a caller‑supplied URL was intentionally left out to avoid a
  server‑side request forgery (SSRF) risk in the current download helper.

These can be added later if needed.

---

## 8. Quick reference

| Action | Method & path | Status |
| --- | --- | --- |
| Create template from PDF/image | `POST /api/templates` | **New (this repo)** |
| Create embeddable CRM template builder session | `POST /api/template_builder_sessions` | **New (this repo)** |
| Create embeddable signing session | `POST /api/signing_sessions` | **New (this repo)** |
| List / get / update / archive templates | `GET/PUT/DELETE /api/templates[/{id}]` | Built‑in |
| Send a document for signing | `POST /api/submissions` | Built‑in |
| List / get submissions | `GET /api/submissions[/{id}]` | Built‑in |
| Download signed documents | `GET /api/submissions/{id}/documents` | Built‑in |
| Read a signer's submitted data | `GET /api/submitters[/{id}]` | Built‑in |

All endpoints authenticate with the `X-Auth-Token` header and are scoped to your account.
