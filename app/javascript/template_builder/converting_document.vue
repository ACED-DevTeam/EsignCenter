<template>
  <div
    class="relative select-none mb-4 rounded border border-base-300 bg-base-100 flex items-center justify-center converting-document"
    :class="{ 'converting-document-failed': isFailed, 'converting-document-timed-out': isTimedOut }"
    :style="{ aspectRatio: '1400 / 1812' }"
  >
    <div class="flex flex-col items-center text-center px-6 max-w-md">
      <template v-if="isFailed">
        <IconFileAlert
          class="w-12 h-12 text-error"
          :stroke-width="1.4"
        />
        <p class="mt-4 text-lg font-medium">
          {{ t('word_conversion_failed_save_as_pdf') }}
        </p>
        <p class="mt-1 text-sm text-base-content/60 break-all">
          {{ filename }}
        </p>
        <button
          v-if="editable"
          class="btn btn-outline btn-sm mt-5 converting-document-remove"
          @click.prevent="$emit('remove', item)"
        >
          {{ t('remove') }}
        </button>
      </template>
      <template v-else-if="isTimedOut">
        <IconClockPause
          class="w-12 h-12 text-base-content/60"
          :stroke-width="1.4"
        />
        <p class="mt-4 text-lg font-medium">
          {{ t('word_conversion_taking_longer_refresh_later') }}
        </p>
        <p class="mt-1 text-sm text-base-content/60 break-all">
          {{ filename }}
        </p>
        <button
          v-if="editable"
          class="btn btn-outline btn-sm mt-5 converting-document-remove"
          @click.prevent="$emit('remove', item)"
        >
          {{ t('remove') }}
        </button>
      </template>
      <template v-else>
        <IconInnerShadowTop
          class="w-12 h-12 animate-spin text-base-content/70"
          :stroke-width="1.4"
        />
        <p class="mt-4 text-lg font-medium">
          {{ t('converting_word_document_') }}
        </p>
        <p class="mt-1 text-sm text-base-content/60 break-all">
          {{ filename }}
        </p>
      </template>
    </div>
  </div>
</template>

<script>
import { IconInnerShadowTop, IconFileAlert, IconClockPause } from '@tabler/icons-vue'

// Stands in for the pages of a Word document until the background conversion
// swaps the PDF in: never a drop target, never a drawing surface.
export default {
  name: 'ConvertingDocument',
  components: {
    IconInnerShadowTop,
    IconFileAlert,
    IconClockPause
  },
  inject: ['t'],
  props: {
    document: {
      type: Object,
      required: true
    },
    item: {
      type: Object,
      required: true
    },
    editable: {
      type: Boolean,
      required: false,
      default: true
    },
    isTimedOut: {
      type: Boolean,
      required: false,
      default: false
    }
  },
  emits: ['remove'],
  computed: {
    isFailed () {
      return !!this.item.conversion_failed
    },
    filename () {
      return this.document.metadata?.original_filename || this.item.name
    }
  }
}
</script>
