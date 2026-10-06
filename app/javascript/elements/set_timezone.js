export default class extends HTMLElement {
  connectedCallback () {
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone

    if (this.dataset.inputId) {
      if (this.dataset.params === 'true') {
        const params = new URLSearchParams(this.input.value)

        params.set('timezone', timezone)

        this.input.value = params.toString()
      } else {
        this.input.value = timezone
      }
    }

    // A form whose server side reads the query string, not the body (the
    // Google sign-in button: OmniAuth keeps only the authorize request's
    // query for the callback).
    if (this.dataset.formId && this.form) {
      const url = new URL(this.form.action, window.location.href)

      url.searchParams.set('timezone', timezone)

      this.form.action = url.toString()
    }
  }

  get input () {
    return document.getElementById(this.dataset.inputId)
  }

  get form () {
    return document.getElementById(this.dataset.formId)
  }
}
