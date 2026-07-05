<template>
  <q-layout view="lHh Lpr lFf">
    <q-header elevated class="bg-dark text-white">
      <q-toolbar>
        <q-icon name="graphic_eq" size="24px" class="q-mr-sm" />
        <q-toolbar-title>{{ t("app.title") }}</q-toolbar-title>
        <q-btn-toggle
          v-model="locale"
          flat
          dense
          no-caps
          toggle-color="cyan-3"
          :options="[
            { label: 'RU', value: 'ru' },
            { label: 'EN', value: 'en' },
          ]"
        />
      </q-toolbar>
    </q-header>

    <q-page-container>
      <router-view />
    </q-page-container>
  </q-layout>
</template>

<script setup lang="ts">
import { watch } from "vue"
import { useI18n } from "vue-i18n"
import { LOCALE_STORAGE_KEY } from "src/boot/i18n"

const { t, locale } = useI18n()

watch(locale, (value) => {
  try {
    globalThis.localStorage?.setItem(LOCALE_STORAGE_KEY, value)
  } catch {
    // ignore storage errors
  }
})
</script>
