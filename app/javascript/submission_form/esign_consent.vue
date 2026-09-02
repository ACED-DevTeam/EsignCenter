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
        aria-describedby="esign_consent_required"
        @change="$emit('update:modelValue', $event.target.checked)"
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
    <p
      id="esign_consent_required"
      :role="error ? 'alert' : undefined"
      :class="error ? 'text-error text-sm mt-1 ps-7' : 'sr-only'"
    >
      {{ config.required_message }}
    </p>
  </div>
</template>

<script>
export default {
  name: 'EsignConsent',
  props: {
    // { label, link_text, required_message, modal_id } — strings come from the
    // Rails partial so config/locales/i18n.yml stays the single source.
    config: {
      type: Object,
      required: true
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
