<template>
  <span
    class="dropdown dropdown-end field-settings-dropdown"
    :class="{ 'dropdown-open': withForceOpen && ((!field.preferences?.price && !field.preferences?.formula && !field.preferences?.price_id && !field.preferences?.payment_link_id) || !isConnected) && !isLoading }"
  >
    <label
      tabindex="0"
      :title="t('settings')"
      class="cursor-pointer text-transparent group-hover:text-base-content"
    >
      <IconSettings
        :width="18"
        :stroke-width="1.6"
      />
    </label>
    <ul
      tabindex="0"
      class="mt-1.5 dropdown-content menu menu-xs p-2 shadow bg-base-100 rounded-box w-52 z-10"
      draggable="true"
      @dragstart.prevent.stop
      @click="closeDropdown"
    >
      <div
        v-if="!('price_id' in field.preferences) && !('payment_link_id' in field.preferences)"
        class="field-settings-currency py-1.5 px-1 relative"
        @click.stop
      >
        <select
          v-model="field.preferences.currency"
          :placeholder="t('price')"
          class="select select-bordered select-xs font-normal w-full max-w-xs !h-7 !outline-0"
          @change="save"
        >
          <option
            v-for="currency in currenciesList"
            :key="currency"
            :value="currency"
          >
            {{ currency }}
          </option>
        </select>
        <label
          :style="{ backgroundColor: backgroundColor }"
          class="absolute -top-1 left-2.5 px-1 h-4"
          style="font-size: 8px"
        >
          {{ t('currency') }}
        </label>
      </div>
      <div
        class="field-settings-price py-1.5 px-1 relative"
        @click.stop
      >
        <input
          v-if="'payment_link_id' in field.preferences"
          v-model="field.preferences.payment_link_id"
          placeholder="plink_XXXXX"
          class="input input-bordered input-xs w-full max-w-xs h-7 !outline-0"
          @blur="save"
        >
        <input
          v-else-if="'price_id' in field.preferences"
          v-model="field.preferences.price_id"
          placeholder="Price ID: price_XXXXX"
          class="input input-bordered input-xs w-full max-w-xs h-7 !outline-0"
          @blur="save"
        >
        <input
          v-else-if="field.preferences.formula"
          type="number"
          :placeholder="t('price')"
          disabled="true"
          class="input input-bordered input-xs w-full max-w-xs h-7 !outline-0"
          @blur="save"
        >
        <input
          v-else
          v-model="field.preferences.price"
          type="number"
          :placeholder="t('price')"
          class="input input-bordered input-xs w-full max-w-xs h-7 !outline-0"
          @blur="save"
        >
        <label
          v-if="(field.preferences.price || field.preferences.price_id || field.preferences.payment_link_id) && (!field.preferences.formula || ('price_id' in field.preferences) || ('payment_link_id' in field.preferences))"
          :style="{ backgroundColor: backgroundColor }"
          class="absolute -top-1 left-2.5 px-1 h-4"
          style="font-size: 8px"
        >
          {{ 'payment_link_id' in field.preferences ? t('payment_link') : t('price') }}
        </label>
        <div class="flex items-center justify-center">
          <a
            href="#"
            class="hover:underline"
            style="font-size: 11px"
            :class="{'underline': !('payment_link_id' in field.preferences)}"
            @click="[delete field.preferences.price_id, delete field.preferences.payment_link_id]"
          >{{ t('one_off') }}</a>
          <span class="h-2.5 border-l border-base-content mx-1" />
          <template
            v-if="field.preferences.price_id"
          >
            <a
              href="#"
              class="hover:underline"
              style="font-size: 11px"
              :class="{'underline': ('price_id' in field.preferences)}"
              @click="field.preferences.payment_link_id ??= ''"
            >{{ t('recurrent') }}</a>
            <span class="h-2.5 border-l border-base-content mx-1" />
          </template>
          <a
            href="#"
            class="hover:underline"
            style="font-size: 11px"
            :class="{'underline': ('payment_link_id' in field.preferences)}"
            @click="[delete field.preferences.price_id, field.preferences.payment_link_id ??= '']"
          >{{ t('payment_link') }}</a>
        </div>
      </div>
      <!--
        The upstream "Connect Stripe" block lived here. It posted to
        /auth/stripe_connect and polled /api/stripe_connect, neither of which
        is a route in this fork — Stripe Connect (collecting payments on a
        signer's behalf) is not a product we sell, and payment fields are off
        everywhere (`withPayment` is false in both builder views). It was
        removed rather than gated so that a builder opened with a payment
        field can never fire a request at a route that does not exist.
      -->
      <li
        v-if="withFormula"
        class="field-settings-formula mb-1"
      >
        <label
          class="label-text cursor-pointer text-center w-full flex items-center"
          @click="$emit('click-formula')"
        >
          <IconMathFunction
            width="18"
          />
          <span class="text-sm">
            {{ 'payment_link_id' in field.preferences ? t('quantity') : t('formula') }}
          </span>
        </label>
      </li>
      <hr>
      <li class="field-settings-description">
        <label
          class="label-text cursor-pointer text-center w-full flex items-center"
          @click="$emit('click-description')"
        >
          <IconInfoCircle
            width="18"
          />
          <span class="text-sm">
            {{ t('description') }}
          </span>
        </label>
      </li>
      <li
        v-if="withCondition"
        class="field-settings-condition mt-1"
      >
        <label
          class="label-text cursor-pointer text-center w-full flex items-center"
          @click="$emit('click-condition')"
        >
          <IconRouteAltLeft
            width="18"
          />
          <span class="text-sm">
            {{ t('condition') }}
          </span>
        </label>
      </li>
      <hr
        v-if="withCustomFields"
        class="pb-0.5 mt-0.5"
      >
      <li
        v-if="withCustomFields"
        class="field-settings-save-as-custom-field"
      >
        <a
          href="#"
          class="text-sm py-1 px-2"
          @click.prevent="$emit('add-custom-field', field)"
        >
          <IconForms
            :width="20"
            :stroke-width="1.6"
          />
          {{ t('save_as_custom_field') }}
        </a>
      </li>
    </ul>
  </span>
</template>

<script>
import { IconMathFunction, IconSettings, IconInfoCircle, IconRouteAltLeft, IconForms } from '@tabler/icons-vue'
import { ref } from 'vue'

const isConnected = ref(false)

export default {
  name: 'PaymentSettings',
  components: {
    IconSettings,
    IconRouteAltLeft,
    IconInfoCircle,
    IconForms,
    IconMathFunction
  },
  inject: ['backgroundColor', 'save', 'currencies', 't', 'isPaymentConnected', 'withFormula'],
  props: {
    field: {
      type: Object,
      required: true
    },
    withForceOpen: {
      type: Boolean,
      required: false,
      default: true
    },
    withCustomFields: {
      type: Boolean,
      required: false,
      default: false
    },
    withCondition: {
      type: Boolean,
      required: false,
      default: true
    }
  },
  emits: ['click-condition', 'click-description', 'click-formula', 'add-custom-field'],
  data () {
    return {
      isLoading: false
    }
  },
  computed: {
    isConnected: () => isConnected.value,
    defaultCurrencies () {
      return ['USD', 'EUR', 'GBP', 'CAD', 'AUD']
    },
    currenciesList () {
      return this.currencies.length ? this.currencies : this.defaultCurrencies
    },
    defaultCurrency () {
      const userTimezone = Intl.DateTimeFormat().resolvedOptions().timeZone

      if (userTimezone.startsWith('Europe')) {
        return 'EUR'
      } else if (userTimezone.includes('London') || userTimezone.includes('Belfast')) {
        return 'GBP'
      } else if (userTimezone.includes('Vancouver') || userTimezone.includes('Toronto') || userTimezone.includes('Halifax') || userTimezone.includes('Edmonton')) {
        return 'CAD'
      } else if (userTimezone.startsWith('Australia')) {
        return 'AUD'
      } else {
        return 'USD'
      }
    }
  },
  created () {
    this.field.preferences ||= {}
  },
  mounted () {
    this.field.preferences.currency ||= this.defaultCurrency

    // No status poll: /api/stripe_connect is not a route in this fork. The
    // only source of truth is the value the server rendered on the builder.
    isConnected.value ||= this.isPaymentConnected
  },
  methods: {
    closeDropdown () {
      document.activeElement.blur()
    }
  }
}
</script>
