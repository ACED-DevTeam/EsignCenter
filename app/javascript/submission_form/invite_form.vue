<template>
  <form
    ref="form"
    action="post"
    method="post"
    class="mx-auto"
    @submit.prevent="submit"
  >
    <input
      type="hidden"
      name="authenticity_token"
      :value="authenticityToken"
    >
    <input
      v-if="esignConsent"
      type="hidden"
      name="esign_consent"
      value="true"
    >
    <input
      v-if="esignConsent"
      type="hidden"
      name="esign_consent_version"
      :value="esignConsentVersion"
    >
    <input
      v-if="esignConsent"
      type="hidden"
      name="esign_consent_locale"
      :value="esignConsentLocale"
    >
    <input
      v-if="esignConsent"
      type="hidden"
      name="esign_consent_locale_token"
      :value="esignConsentLocaleToken"
    >
    <input
      v-if="esignConsent && esignConsentPdfUrl"
      type="hidden"
      name="esign_consent_pdf_opened"
      :value="esignConsentPdfOpened"
    >
    <input
      v-if="esignConsent"
      type="hidden"
      name="esign_consent_sender_digest"
      :value="esignConsentSenderDigest"
    >
    <div
      v-for="(submitter, index) in [...submitters, ...optionalSubmitters]"
      :key="submitter.uuid"
      :class="{ 'mt-4': index !== 0 }"
    >
      <input
        :value="submitter.uuid"
        hidden
        name="submission[submitters][][uuid]"
      >
      <label
        :for="submitter.uuid"
        dir="auto"
        class="label text-2xl"
      >
        {{ t('invite') }} {{ submitter.name }} <template v-if="!submitters.includes(submitter)">({{ t('optional') }})</template>
      </label>
      <input
        :id="submitter.uuid"
        dir="auto"
        class="base-input !text-2xl w-full"
        :placeholder="t('email')"
        type="email"
        :required="submitters.includes(submitter)"
        autofocus="true"
        name="submission[submitters][][email]"
      >
    </div>
    <div
      class="mt-4 md:mt-6"
    >
      <button
        type="submit"
        class="base-button w-full flex justify-center"
        :disabled="isSubmitting"
      >
        <span class="flex">
          <IconInnerShadowTop
            v-if="isSubmitting"
            class="mr-1 animate-spin"
          />
          <span>
            {{ t('complete') }}
          </span><span
            v-if="isSubmitting"
            class="w-6 flex justify-start mr-1"
          ><span>...</span></span>
        </span>
      </button>
    </div>
  </form>
</template>

<script>
import { IconInnerShadowTop } from '@tabler/icons-vue'

export default {
  name: 'InviteForm',
  components: {
    IconInnerShadowTop
  },
  inject: ['t'],
  props: {
    submitters: {
      type: Array,
      required: true
    },
    fetchOptions: {
      type: Object,
      required: false,
      default: () => ({})
    },
    optionalSubmitters: {
      type: Array,
      required: false,
      default: () => []
    },
    url: {
      type: String,
      required: true
    },
    authenticityToken: {
      type: String,
      required: true
    },
    submitterSlug: {
      type: String,
      required: true
    },
    // The signer ticked the ESIGN consent box during this signing: the invite
    // request (the last one of an invite-then-complete flow) carries it too.
    esignConsent: {
      type: Boolean,
      required: false,
      default: false
    },
    // The disclosure version the signer agreed to (sent with the consent).
    esignConsentVersion: {
      type: String,
      required: false,
      default: ''
    },
    // The locale the disclosure was shown in (sent with the consent).
    esignConsentLocale: {
      type: String,
      required: false,
      default: ''
    },
    // The server's signature over that locale: it is what binds the recorded
    // language to the page that rendered it (sent with the consent).
    esignConsentLocaleToken: {
      type: String,
      required: false,
      default: ''
    },
    // Whether the signer opened the document as a PDF before agreeing (sent
    // with the consent; the browser's own claim, stored as such).
    esignConsentPdfOpened: {
      type: Boolean,
      required: false,
      default: false
    },
    // The "View this document as a PDF" link the signing page offered, if any.
    // With no link there is no question to answer, so the claim above is not
    // sent at all and the record says it was never taken.
    esignConsentPdfUrl: {
      type: String,
      required: false,
      default: ''
    },
    // Fingerprint of the sender name and address the disclosure showed; the
    // server refuses the consent if they have changed since (sent with it).
    esignConsentSenderDigest: {
      type: String,
      required: false,
      default: ''
    }
  },
  emits: ['success'],
  data () {
    return {
      isSubmitting: false
    }
  },
  methods: {
    submit () {
      this.isSubmitting = true

      return fetch(this.url, {
        method: 'POST',
        body: new FormData(this.$refs.form),
        ...this.fetchOptions
      }).then((response) => {
        if (response.status === 200) {
          this.$emit('success')
        }
      }).finally(() => {
        this.isSubmitting = false
      })
    }
  }
}
</script>
