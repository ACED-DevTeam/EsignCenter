// Zod 4 probes for `new Function` the first time it compiles a schema, to
// decide whether it may use its faster JIT path. Under this application's
// `script_src 'self'` policy that probe is blocked: the throw is caught and
// Zod carries on correctly, but the browser still fires a
// `securitypolicyviolation` — a real report of a real blocked eval, on a page
// that is meant to have none.
//
// `jitless` is Zod's own switch for exactly this case (its source says so:
// "Skip the probe under `jitless`"). Setting it on the shared global config
// means the interpreted path is chosen without ever asking the browser.
//
// Imported FIRST by any pack that pulls in a Zod-using dependency, so it runs
// before that dependency's module body: ES imports are evaluated in order.
import { config } from 'zod/v4/core'

config({ jitless: true })
