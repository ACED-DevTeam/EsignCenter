// Browser-side error reporting is intentionally local: there is no browser
// error tracker in this deployment, so problems are surfaced on the console
// where support can ask a signer to read them out.
function reportError (message) {
  console.error(message)
}

export { reportError }
