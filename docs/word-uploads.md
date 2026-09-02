# Word uploads (.docx / .doc)

EsignCenter accepts Word documents wherever a PDF can be uploaded from the
web app: the dashboard upload button and drop zone, and the template builder's
"Add document" and "Replace" buttons. The file is converted to PDF in the
background with LibreOffice; the template then works exactly like one built
from a PDF.

The public API, the MCP tools and signing sessions keep accepting **PDF and
images only** (a Word document gets the usual `422 Unsupported document
format`). Their contract is synchronous — the caller gets a finished template
back — and a conversion is not.

## What users see

1. The upload finishes at once. The builder opens and the Word document shows
   a **"Converting Word document…"** card (spinner and the file name) where its
   pages will be. Nothing can be dropped or drawn on that card.
2. The builder checks every 3 seconds. When the PDF is ready the pages appear
   in place — no reload. If the Word file contained form fields, the usual
   "keep or remove them" prompt appears, as it does for a PDF.
3. If the conversion fails, the card says **"We couldn't convert this Word
   document. Save it as a PDF and upload again."** with the normal Remove
   button. A conversion that is still running after 5 minutes shows "This is
   taking longer than expected. Refresh the page later." — also with the
   Remove button. Pressing Remove takes the document out of the template and
   unblocks sending right away; a conversion job that has not started yet
   then finds nothing to do and skips the conversion (a job already
   converting finishes, but the result belongs to nothing). A document still
   marked converting **30 minutes** after its conversion last showed
   progress — LibreOffice being started on it, or the half-way PDF being
   stored; time spent waiting in the queue or waiting for a free conversion
   slot does not count — has lost its job; the app treats it as failed from
   then on, so a template is never blocked forever.
4. If the conversion finished while nobody had the builder open, the form
   fields found in the Word file are added the next time the builder opens
   (with the same keep-or-remove prompt), not lost — and they survive an
   autosave from a builder that was open when the conversion finished but
   had stopped checking. "Remove" on that prompt removes only the fields
   found in the Word file; every other field on the template stays.

**Nothing can be sent while a document is converting.** A template whose
document is still converting — or failed to convert — is not ready for
signing: the builder's Send and Sign-yourself buttons are held back with a
tooltip, and every way of starting a signing (the send dialog, the API, the
MCP tools, signing sessions, the shared link, "sign yourself", resubmit) is
refused with "This template has a document that is still being converted.
Try again in a moment." or, for a failed document, "A document in this
template could not be converted. Remove it or upload it as a PDF." The API
answers `422` with the same message. Cloning such a template (from the
dashboard, the API or an embedded builder session) is refused with the same
message too: a copy would share the unconverted file and never finish.

The readiness check reads the stored documents themselves, not the builder's
copy of the template: saving in the builder, reloading it, or an autosave that
lands mid-conversion cannot make a converting document look ready, and after
a reload the builder shows the converting (or failed) card again and keeps
checking.

A file that cannot be accepted is refused straight away with a specific
message — no template or document is created, even when other files in the
same upload were fine. Files are recognised by their contents, not by the
name or type the browser sends: a Word file called `.pdf`, or sent as a zip,
is still treated as a Word file.

| Situation | Message |
|---|---|
| Not a PDF, image or Word file (a spreadsheet, for instance) | "This file format isn't supported. Upload a PDF, an image, or a Word document (.docx, .doc)." |
| Word file larger than 20 MB | "This Word document is too large. The limit is 20 MB — save it as a PDF or split it up." |
| More than 30 Word conversions from one account in an hour | "Too many Word documents were converted in the last hour. Try again later or upload a PDF." |
| Conversion switched off, or LibreOffice missing | "Word documents can't be converted right now. Save the file as a PDF and upload it again." |

While the file is being converted it is stored as uploaded. Once the PDF is
in place, the deletion of the original Word file is queued as the conversion
finishes (a small background job removes it moments later); only the PDF is
kept.

## Limits and guards

| Guard | Value | Where |
|---|---|---|
| File size | 20 MB | `WordConverter::MAX_FILE_SIZE` |
| Time per conversion | 120 seconds, then the LibreOffice process group is killed | `WordConverter::TIMEOUT_SECONDS` |
| Conversions running at once (whole instance) | 2 | `WordConverter::MAX_CONCURRENT` |
| Conversions per account | 30 per hour | `Templates::CreateAttachments::WORD_CONVERSIONS_PER_HOUR` |
| Queue | `documents`, fetch weight 1 on the shared worker pool (not a thread of its own) | `config/sidekiq.yml` |

Each conversion runs in its own temporary directory with its own LibreOffice
profile and is removed afterwards. LibreOffice is started directly (never
through a shell) with the file's bytes written to disk under a fixed name, so
the file name a user chose never reaches the command line. A cold first
launch of LibreOffice on a fresh container can die before producing anything;
the converter retries once with a fresh directory before giving up.

When every slot is busy the job waits 15 seconds and tries again, for up to
about 10 minutes, before marking the document failed. A document that
LibreOffice cannot convert, or that times out, is marked failed at once and
reported to Sentry as a warning; it is not retried (the result would be the
same). Storage or database errors are retried by Sidekiq as usual (3 tries);
when those run out the document is marked failed too. The job keeps its
"still converting" markers until the PDF is stored, the template updated and
the Word file's deletion queued; clearing the markers is its very last step,
so a retry after a failure at any point — even in that last step — resumes
where it left off without converting again.

## Operator switches

| Variable | Default | Effect |
|---|---|---|
| `WORD_CONVERSION_ENABLED` | unset (on) | Set to exactly `false` to switch Word uploads off. The upload forms stop offering `.docx`/`.doc`, and a Word file sent anyway is refused with the "can't be converted right now" message. Jobs already queued still run. This is the kill switch to reach for if LibreOffice misbehaves in production. |
| `SOFFICE_PATH` | `soffice` (found on `PATH`) | Full path to the LibreOffice binary when it is not on `PATH`. If the binary cannot be found, Word uploads behave as if the switch were off. |

Both are optional; nothing else needs configuring.

## Resources (launch-gate 3)

- **Image size.** LibreOffice Writer plus the metric-compatible fonts
  (Liberation, Carlito, DejaVu) add roughly **800 MB** to the Docker image.
  Accepted as decision D48; expect longer image pulls and builds on Render.
- **Memory.** A conversion can take a few hundred megabytes for the duration
  of the LibreOffice process, and two may run at once. The conversion runs
  inside the same container as the web server, the job worker and the
  embedded Redis, so a container that hits its memory limit takes all of them
  down with it (see `docs/operations.md` section 5, "Memory contention with
  LibreOffice"). Plan for the Standard tier at least and confirm the limit at
  launch-gate 3.
- **CPU.** Conversions are CPU-bound for a few seconds each. The `documents`
  entry in `config/sidekiq.yml` is only a fetch weight: the embedded Sidekiq
  runs its `SIDEKIQ_THREADS` worker threads across every queue, so the queue
  itself does not limit how many conversions run. The real cap is the
  two slot keys in Redis (`WordConverter::MAX_CONCURRENT`), each taken
  atomically and released only by the worker holding it: at most two
  LibreOffice processes at once, whatever the worker pool is doing — and if
  the store (Redis) cannot answer, the job waits and retries rather than run
  unaccounted.
