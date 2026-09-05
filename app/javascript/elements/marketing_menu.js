// The marketing header's phone menu. Wraps a toggle button and the panel it
// controls (`data-toggle` / `data-panel`); the button carries `aria-expanded`
// and `aria-controls` so a screen reader hears the state, Enter and Space
// work because it is a real <button>, and Escape closes the panel and hands
// focus back to the button. Nothing here is needed at desktop widths, where
// the panel's links are laid out inline by CSS.
export default class extends HTMLElement {
  connectedCallback () {
    this.toggle = this.querySelector('[data-toggle]')
    this.panel = this.querySelector('[data-panel]')

    if (!this.toggle || !this.panel) return

    // Tells a test (and any stylesheet) that the menu is wired up.
    this.dataset.ready = 'true'

    this.toggle.addEventListener('click', () => this.setOpen(!this.isOpen()))

    this.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && this.isOpen()) {
        this.setOpen(false)
        this.toggle.focus()
      }
    })

    // A click outside (or a Turbo navigation away) leaves no stale open menu.
    document.addEventListener('click', this.onDocumentClick)
  }

  disconnectedCallback () {
    document.removeEventListener('click', this.onDocumentClick)
  }

  onDocumentClick = (event) => {
    if (this.isOpen() && !this.contains(event.target)) this.setOpen(false)
  }

  isOpen () {
    return this.toggle.getAttribute('aria-expanded') === 'true'
  }

  setOpen (open) {
    this.toggle.setAttribute('aria-expanded', String(open))
    this.panel.classList.toggle('mk-menu-open', open)
    this.querySelectorAll('[data-icon-open]').forEach((el) => el.classList.toggle('hidden', !open))
    this.querySelectorAll('[data-icon-closed]').forEach((el) => el.classList.toggle('hidden', open))
  }
}
