export default class extends HTMLElement {
  connectedCallback () {
    let active = null

    this.querySelectorAll('a').forEach((link) => {
      // Whatever a previous render left behind: exactly one link may claim it.
      link.removeAttribute('aria-current')

      if (link.getAttribute('href').startsWith('http')) return
      if (!document.location.pathname.startsWith(link.pathname)) return

      link.classList.add('bg-base-300')

      // The "Back" arrow points at `/`, which every path starts with — it is
      // the way out of settings, never the page you are on. Longest match
      // wins, so the tab that is really open is the one announced. On a phone
      // the tabs are told apart by a background colour alone, and colour is
      // not something a screen reader reads out.
      if (link.pathname === '/') return
      if (!active || link.pathname.length > active.pathname.length) active = link
    })

    if (!active) return

    active.setAttribute('aria-current', 'page')

    // On a phone the menu is a strip that scrolls sideways, and the tab you
    // are on is often past the right edge of it — Webhooks and Export sit off
    // screen, so the strip opens looking like it has no active tab at all.
    // Bring it into the middle. The test is the strip's own overflow, which
    // is also the breakpoint guard: from `md` the menu is the vertical
    // sidebar, nothing overflows, and the desktop page never jumps.
    const strip = active.closest('.settings-tabs') || active.closest('ul')

    if (!strip || strip.scrollWidth <= strip.clientWidth) return

    // Scrolled directly rather than through `scrollIntoView`, which walks up
    // and nudges every scrollable ancestor it finds — including the page,
    // which has no business moving because a tab needed centring. This
    // touches one element on one axis.
    const tab = active.getBoundingClientRect()
    const box = strip.getBoundingClientRect()

    strip.scrollLeft += tab.left - box.left - (strip.clientWidth - tab.width) / 2
  }
}
