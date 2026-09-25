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
        :aria-invalid="error ? 'true' : undefined"
        :aria-describedby="error ? 'esign_consent_error' : undefined"
        @change="onChange"
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
        name="esign_consent_locale_token"
        :value="config.locale_token"
      >
      <input
        v-if="config.pdf_url"
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
          class="cursor-pointer"
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
    // { version, locale, locale_token, label, link_text, required_message,
    // stale_message, locale_invalid_message, modal_id, pdf_url,
    // view_pdf_text, sender_digest } — strings come from the
    // Rails partial so config/locales/i18n.yml stays the single source.
    // `version`, `locale`,
    // `locale_token` and `sender_digest` are sent back with the consent: the
    // server refuses a consent given on an outdated disclosure or one that
    // named a different sender, and records which language the signer read it
    // in — the language named by `locale_token`, the server's own signature
    // over what this page rendered, not by the completion request's headers.
    config: {
      type: Object,
      required: true
    },
    // The signer followed the "View this document as a PDF" link at least
    // once. Opening it is optional: the disclosure asks the signer to confirm
    // they can open, save or print the PDF when they tick the box, and the
    // link is there so they can check. The answer is still worth keeping as
    // evidence. It lives in the parent form so the invite request can send it too,
    // and it travels with the consent as `esign_consent_pdf_opened` — but only
    // when there IS a link (`config.pdf_url`). With nothing to serve no link is
    // drawn, so there is no question to answer and nothing is posted: the
    // record then says the answer was not taken, never that the signer
    // declined to open a link they were never shown.
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
    // The server could not confirm which language the disclosure was shown
    // in. A different refusal from `stale` and it says so — nothing was
    // updated, and telling somebody it was would be a lie in the one place
    // this product cannot afford one.
    localeInvalid: {
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
    // Read by assistive tech in two places: the live region announces it
    // when it appears; the always-present sr-only copy describes the disabled
    // action buttons (form.vue points their aria-describedby at it).
    message () {
      if (this.localeInvalid) return this.config.locale_invalid_message
      if (this.stale) return this.config.stale_message

      return this.config.required_message
    }
  },
  methods: {
    focus () {
      this.$refs.checkbox?.focus()
    },
    onChange (event) {
      this.$emit('update:modelValue', event.target.checked)
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
