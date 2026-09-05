export default class extends HTMLElement {
  connectedCallback () {
    let active = null

    this.querySelectorAll('a').forEach((link) => {
      // Whatever a previous render left behind: exactly one link may claim it.
      link.removeAttribute('aria-current')

      if ((link.getAttribute('href') || '').startsWith('http')) return
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

    if (active) active.setAttribute('aria-current', 'page')
  }
}
