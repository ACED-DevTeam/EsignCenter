const emailRegexp = /([^@;,<>\s]+@[^@;,<>\s]+)/g

export default class extends HTMLElement {
  connectedCallback () {
    if (this.dataset.limit) {
      this.textarea.addEventListener('input', () => {
        const emails = this.textarea.value.match(emailRegexp) || []

        this.updateCounter(emails.length)
      })
    }
  }

  updateCounter (count) {
    let counter = document.getElementById('emails_counter')

    if (count < 2) {
      counter?.remove()

      return
    }

    if ((count + 10) > this.dataset.limit) {
      if (!counter) {
        counter = document.createElement('span')

        counter.id = 'emails_counter'
        counter.classList.add('text-xs', 'right-0', 'absolute')
        counter.style.bottom = '-15px'

        this.textarea.parentNode.append(counter)
      }

      counter.innerText = `${count} / ${this.dataset.limit}`
    }
  }

  get textarea () {
    return this.querySelector('textarea')
  }
}
