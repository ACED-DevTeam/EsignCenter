// A form that saves itself on change answers with a bare 200 and no page, so
// without this nothing on screen said the setting had stuck, and a refused or
// failed save left the switch showing a value that was never stored. Several
// <submit-form> elements can share one form, so it is watched only once.
const watchedForms = new WeakSet()

const TOAST_DURATION = { saved: 2500, failed: 6000 }

let toastTimeout

const showToast = (kind) => {
  const template = document.getElementById(`autosave_${kind}_toast`)

  if (!template) return

  clearTimeout(toastTimeout)

  window.flash?.remove()
  document.getElementById('autosave_toast')?.remove()

  const toast = template.content.firstElementChild.cloneNode(true)

  document.body.append(toast)

  toastTimeout = setTimeout(() => toast.remove(), TOAST_DURATION[kind])
}

const snapshotInputs = (form) => {
  return Array.from(form.elements).filter((el) => el.matches('input:not([type="hidden"]), select, textarea')).map((el) => {
    return [el, ['checkbox', 'radio'].includes(el.type) ? el.checked : el.value]
  })
}

const restoreInputs = (snapshot) => {
  snapshot.forEach(([el, value]) => {
    if (['checkbox', 'radio'].includes(el.type)) {
      el.checked = value
    } else {
      el.value = value
    }
  })
}

const watchSaveResult = (form) => {
  if (watchedForms.has(form) || form.method === 'get') return

  watchedForms.add(form)

  let snapshot = snapshotInputs(form)

  // Keep a refused save on this page: Turbo would otherwise swap the whole
  // page for the error response.
  form.addEventListener('turbo:before-fetch-response', (event) => {
    if (!event.detail.fetchResponse.succeeded) {
      event.preventDefault()
    }
  })

  form.addEventListener('turbo:submit-end', (event) => {
    const { success, fetchResponse } = event.detail

    if (!success) {
      restoreInputs(snapshot)

      showToast('failed')
    } else if (!fetchResponse?.redirected) {
      // A redirect re-renders the page with its own notice; a bare answer
      // gets one here.
      snapshot = snapshotInputs(form)

      showToast('saved')
    }
  })
}

export default class extends HTMLElement {
  connectedCallback () {
    const form = this.querySelector('form') || (this.querySelector('input, button, select') || this.lastElementChild).form

    if (this.dataset.interval) {
      this.interval = setInterval(() => {
        form.requestSubmit()
      }, parseInt(this.dataset.interval))
    } else if (this.dataset.on) {
      watchSaveResult(form)

      this.lastElementChild.addEventListener(this.dataset.on, (event) => {
        if (this.dataset.disable === 'true') {
          form.querySelector('[type="submit"]')?.setAttribute('disabled', true)
        }

        if (this.dataset.submitIfValue === 'true') {
          if (event.target.value) {
            form.requestSubmit()
          }
        } else {
          form.requestSubmit()
        }
      })
    } else {
      form.requestSubmit()
    }
  }

  disconnectedCallback () {
    if (this.interval) {
      clearInterval(this.interval)
    }
  }
}
