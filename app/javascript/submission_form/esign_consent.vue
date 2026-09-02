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
    // modal_id } — strings come from the Rails partial so
    // config/locales/i18n.yml stays the single source. `version` and `locale`
    // are sent back with the consent: the server refuses a consent given on
    // an outdated disclosure and records which language the signer read it in.
    config: {
      type: Object,
      required: true
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
  emits: ['update:modelValue'],
  computed: {
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
