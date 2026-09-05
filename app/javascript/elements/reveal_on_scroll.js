// Fades a marketing section in as it scrolls into view. The content is
// visible before this runs: the element only opts into the animation (the
// `mk-reveal` class) once it knows it can finish it — IntersectionObserver
// exists and the reader has not asked for reduced motion — so a page without
// JavaScript, or a reader who prefers stillness, sees everything at once.
//
// An observer only fires when a section crosses its threshold, so a jump
// from the top of the page to the bottom (the End key, a footer link) would
// leave everything in between at opacity 0. One shared scroll listener,
// throttled to a frame, shows any section that is already above the viewport.
let watchingScroll = false

const revealScrolledPast = () => {
  document.querySelectorAll('reveal-on-scroll.mk-reveal:not(.mk-revealed)').forEach((element) => {
    if (element.getBoundingClientRect().bottom < 0) element.reveal()
  })
}

const watchScroll = () => {
  if (watchingScroll) return

  watchingScroll = true

  let scheduled = false

  document.addEventListener('scroll', () => {
    if (scheduled) return

    scheduled = true

    window.requestAnimationFrame(() => {
      scheduled = false
      revealScrolledPast()
    })
  }, { passive: true })
}

export default class extends HTMLElement {
  connectedCallback () {
    if (!('IntersectionObserver' in window)) return
    if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return

    this.classList.add('mk-reveal')

    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        // Not yet reached, and not already scrolled past (a page opened
        // mid-way through an anchor): wait.
        if (!entry.isIntersecting && entry.boundingClientRect.bottom >= 0) return

        this.reveal()
      })
    }, { rootMargin: '0px 0px -10% 0px', threshold: 0.1 })

    this.observer.observe(this)

    watchScroll()
  }

  reveal () {
    this.classList.add('mk-revealed')
    this.observer?.disconnect()
  }

  disconnectedCallback () {
    this.observer?.disconnect()
  }
}
