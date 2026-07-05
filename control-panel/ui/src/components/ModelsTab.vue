<template>
  <div>
    <q-banner v-if="error" class="bg-red-9 text-white q-mb-md" rounded>
      {{ t("common.error") }}: {{ error }}
    </q-banner>

    <div class="text-subtitle1 q-mb-xs">{{ t("models.title") }}</div>
    <div class="text-caption text-grey-5 q-mb-sm">{{ t("models.hint") }}</div>

    <q-markup-table flat bordered dense class="bg-dark">
      <thead>
        <tr>
          <th class="text-left">{{ t("models.model") }}</th>
          <th class="text-left">{{ t("models.status") }}</th>
          <th class="text-right">{{ t("models.actions") }}</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="m in models" :key="m.id">
          <td class="text-left">
            {{ m.model }}
            <q-badge color="blue-grey-7" class="q-ml-sm" :label="m.kind" />
            <div v-if="m.note" class="text-caption text-grey-6">
              {{ t("models.staged") }}: {{ m.note }}
            </div>
          </td>
          <td class="text-left">
            <q-chip v-if="m.downloading" color="blue-8" text-color="white" dense size="sm" icon="downloading">
              {{ t("models.downloading") }}
            </q-chip>
            <q-chip v-else-if="m.downloaded" color="green-7" text-color="white" dense size="sm" icon="check">
              {{ m.sizeMb }} MB
            </q-chip>
            <q-chip v-else color="grey-7" text-color="white" dense size="sm">{{ t("models.missing") }}</q-chip>
          </td>
          <td class="text-right">
            <q-btn
              v-if="m.downloadable"
              dense
              flat
              icon="download"
              :label="t('models.download')"
              :disable="m.downloading"
              :loading="m.downloading"
              @click="doDownload(m.id)"
            />
            <span v-else class="text-caption text-grey-6">{{ t("models.notDownloadable") }}</span>
          </td>
        </tr>
      </tbody>
    </q-markup-table>
    <div class="text-caption text-grey-6 q-mt-sm">{{ t("models.pollNote") }}</div>
  </div>
</template>

<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue"
import { useI18n } from "vue-i18n"
import { downloadModel, fetchModels } from "src/services/api"
import type { ModelStatus } from "src/types"

const { t } = useI18n()

const models = ref<ModelStatus[]>([])
const error = ref<string | null>(null)
let timer: ReturnType<typeof setInterval> | undefined

const reload = async (): Promise<void> => {
  try {
    models.value = await fetchModels()
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  }
}

const doDownload = async (id: string): Promise<void> => {
  error.value = null
  try {
    const result = await downloadModel(id)
    if (!result.started) {
      error.value = result.reason ?? "download did not start"
    }
    await reload()
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  }
}

onMounted(() => {
  void reload()
  timer = setInterval(() => void reload(), 3000)
})
onUnmounted(() => {
  if (timer !== undefined) clearInterval(timer)
})
</script>
