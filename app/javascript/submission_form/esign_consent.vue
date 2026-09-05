<template>
  <div
    class="esign-consent mb-3 md:mb-4"
    dir="auto"
  >
    <div class="flex items-start gap-2">
      <input
        id="esign_consent"
        ref="checkbox"
        type="checkbox"
        name="esign_consent"
        value="true"
        class="checkbox checkbox-sm mt-0.5 flex-none"
        :checked="modelValue"
        :disabled="isPdfGateClosed"
        :aria-invalid="error ? 'true' : undefined"
        :aria-describedby="describedBy"
        @change="$emit('update:modelValue', $event.target.checked)"
      >
      <input
        type="hidden"
        name="esign_consent_version"
        :value="config.version"
      >
      <input
        type="hidden"
        name="esign_consent_locale"
        :value="config.locale"
      >
      <input
        type="hidden"
        name="esign_consent_pdf_opened"
        :value="pdfOpened"
      >
      <input
        type="hidden"
        name="esign_consent_sender_digest"
        :value="config.sender_digest"
      >
      <div class="text-sm sm:text-base leading-snug">
        <label
          for="esign_consent"
          :class="isPdfGateClosed ? 'opacity-60' : 'cursor-pointer'"
        >
          {{ config.label }}
        </label>
        <button
          type="button"
          class="link link-hover font-medium"
          @click="openDisclosure"
        >
          {{ config.link_text }}
        </button>
        <a
          v-if="config.pdf_url"
          id="esign_consent_view_pdf"
          :href="config.pdf_url"
          target="_blank"
          rel="noopener"
          class="link link-hover font-medium block mt-1"
          @click="markPdfOpened"
        >
          {{ config.view_pdf_text }}
        </a>
        <p
          v-if="isPdfGateClosed"
          id="esign_consent_open_pdf_first"
          class="text-base-content/60 text-sm mt-1"
        >
          {{ config.open_pdf_first }}
        </p>
      </div>
    </div>
    <div aria-live="polite">
      <p
        v-if="error"
        id="esign_consent_error"
        class="text-error text-sm mt-1 ps-7"
      >
        {{ message }}
      </p>
    </div>
    <p
      id="esign_consent_required"
      class="sr-only"
    >
      {{ message }}
    </p>
  </div>
</template>

<script>
export default {
  name: 'EsignConsent',
  props: {
    // { version, locale, label, link_text, required_message, stale_message,
    // modal_id, pdf_url, view_pdf_text, open_pdf_first, sender_digest } —
    // strings come from the Rails partial so config/locales/i18n.yml stays the
    // single source. `version`, `locale` and `sender_digest` are sent back with
    // the consent: the server refuses a consent given on an outdated disclosure
    // or one that named a different sender, and records which language the
    // signer read it in.
    config: {
      type: Object,
      required: true
    },
    // The signer followed the "View this document as a PDF" link at least
    // once. It lives in the parent form so the invite request can send it too,
    // and it travels with the consent as `esign_consent_pdf_opened`.
    pdfOpened: {
      type: Boolean,
      required: false,
      default: false
    },
    // The server refused the version this page displayed: the signer has to
    // reload and agree again.
    stale: {
      type: Boolean,
      required: false,
      default: false
    },
    modelValue: {
      type: Boolean,
      required: false,
      default: false
    },
    error: {
      type: Boolean,
      required: false,
      default: false
    }
  },
  emits: ['update:modelValue', 'pdfOpened'],
  computed: {
    // §7001(c) asks the signer to confirm their device can display the record
    // before they agree to receive it electronically, so the box stays out of
    // reach until they have opened the PDF once. No link (the config carries
    // no URL), no gate.
    isPdfGateClosed () {
      return !!this.config.pdf_url && !this.pdfOpened
    },
    describedBy () {
      if (this.error) return 'esign_consent_error'

      return this.isPdfGateClosed ? 'esign_consent_open_pdf_first' : undefined
    },
    // Read by assistive tech in two places: the live region announces it
    // when it appears; the always-present sr-only copy describes the disabled
    // action buttons (form.vue points their aria-describedby at it).
    message () {
      return this.stale ? this.config.stale_message : this.config.required_message
    }
  },
  methods: {
    focus () {
      this.$refs.checkbox?.focus()
    },
    // Client attestation, and stored as one: the browser says the link was
    // followed, nothing proves the person read what opened.
    markPdfOpened () {
      this.$emit('pdfOpened')
    },
    openDisclosure () {
      const dialog = document.getElementById(this.config.modal_id)

      if (!dialog) return

      // Same handshake as the modal-button element: the Rails dialog is inert
      // while closed so its controls stay out of the tab order.
      dialog.inert = false
      dialog.addEventListener('close', () => { dialog.inert = true }, { once: true })
      dialog.showModal()
    }
  }
}
</script>
