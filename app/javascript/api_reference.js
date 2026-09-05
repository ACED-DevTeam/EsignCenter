// The public API reference at /docs/api (ApiReferenceController).
//
// Its own pack on purpose: Scalar is a large bundle and every other page in
// the application would otherwise pay for it. It is loaded from this origin,
// never a CDN, because the whole application runs under `script_src 'self'`
// (ApplicationController#set_csp) and a reference page is not a reason to
// widen that.
//
// Everything that would reach off this origin at runtime is switched off:
// Scalar's default web fonts (a remote stylesheet), its hosted request proxy
// and the "try it" client that uses it. The page documents the API; the place
// to exercise it is a terminal with a real token.
// Must come first: it switches off a Zod probe that would otherwise trip the
// page's security policy (see the file for why).
import './lib/zod_jitless'
import { createApiReference } from '@scalar/api-reference'
import '@scalar/api-reference/style.css'

const MOUNT_ID = 'api-reference'

const mount = () => {
  const element = document.getElementById(MOUNT_ID)

  if (!element || element.dataset.mounted === 'true') return

  element.dataset.mounted = 'true'

  createApiReference(element, {
    // Same origin as this page: no CORS, and nothing to allow in connect-src
    // beyond 'self'.
    url: element.dataset.specUrl,
    // Scalar's default web fonts are a remote stylesheet; the page uses the
    // application's own type stack instead.
    withDefaultFonts: false,
    // The reference lives inside a light marketing page and must not fight it.
    darkMode: false,
    forceDarkModeState: 'light',
    hideDarkModeToggle: true,
    // Everything Scalar would otherwise send off this origin, or offer that is
    // not ours: its hosted request proxy and the "try it" client that needs
    // one, its AI assistant, its MCP integration, and the developer toolbar it
    // shows on localhost.
    proxyUrl: '',
    hideTestRequestButton: true,
    hideClientButton: true,
    agent: { disabled: true },
    mcp: { disabled: true },
    showDeveloperTools: 'never',
    documentDownloadType: 'json',
    showSidebar: true,
    // The browser tab keeps the page's own title rather than following
    // whichever operation happens to be in view.
    setPageTitle: () => 'API reference — EsignCenter'
  })
}

document.addEventListener('DOMContentLoaded', mount)
document.addEventListener('turbo:load', mount)
