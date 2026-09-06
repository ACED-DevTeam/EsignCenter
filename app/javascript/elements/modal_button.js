// The button that opens one of the app's <dialog> modals, named by the id of
// the dialog it opens.
//
// That id is read from `data-modal-id` and NOT from `data-target` (session 10
// walk, W3). `data-target` belongs to @github/catalyst, whose tag observer
// scans every element added to the page for one and reads the value as
// `custom-element.property` — so a bare id was handed to `closest()` as a CSS
// selector, and every modal id that begins with a digit (a plain UUID, most of
// the time) threw a SyntaxError into the console on any page carrying a modal.
export default class extends HTMLElement {
  connectedCallback () {
    const dialog = document.getElementById(this.dataset.modalId)

    this.querySelector('button').addEventListener('click', () => {
      if (dialog) {
        dialog.inert = false
        dialog.showModal()
      }
    })

    if (dialog) {
      dialog.addEventListener('close', () => {
        dialog.inert = true
      })
    }
  }
}
