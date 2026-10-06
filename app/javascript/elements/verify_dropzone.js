import { target, targetable } from '@github/catalyst/lib/targetable'

// Progressive enhancement for the public /verify upload: drag-and-drop onto
// the label and a visible file name. The form itself works without it.
export default targetable(class extends HTMLElement {
  static [target.static] = [
    'input',
    'filename',
    'area'
  ]

  connectedCallback () {
    this.addEventListener('dragover', this.onDragover)
    this.addEventListener('dragleave', this.onDragleave)
    this.addEventListener('drop', this.onDrop)
    this.input?.addEventListener('change', this.showFilename)
  }

  disconnectedCallback () {
    this.removeEventListener('dragover', this.onDragover)
    this.removeEventListener('dragleave', this.onDragleave)
    this.removeEventListener('drop', this.onDrop)
    this.input?.removeEventListener('change', this.showFilename)
  }

  onDragover = (e) => {
    if (e.dataTransfer?.types?.includes('Files')) {
      e.preventDefault()

      this.area?.classList.add('border-base-content/60', 'bg-base-200')
    }
  }

  onDragleave = () => {
    this.area?.classList.remove('border-base-content/60', 'bg-base-200')
  }

  onDrop = (e) => {
    e.preventDefault()

    this.onDragleave()

    const file = e.dataTransfer?.files?.[0]

    if (!file || !this.input) return

    const transfer = new DataTransfer()

    transfer.items.add(file)

    this.input.files = transfer.files

    this.showFilename()
  }

  showFilename = () => {
    const file = this.input?.files?.[0]

    if (!this.filename) return

    this.filename.textContent = file ? file.name : ''
    this.filename.classList.toggle('hidden', !file)
  }
})
