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
            <div
              v-for="p in m.paths"
              :key="p"
              class="text-caption text-grey-7"
              style="font-family: monospace; word-break: break-all"
            >
              {{ p }}
            </div>
          </td>
          <td class="text-left">
            <q-chip v-if="m.downloading" color="blue-8" text-color="white" dense size="sm" icon="downloading">
              {{ t("models.downloading") }}
            </q-chip>
            <q-chip v-else-if="m.downloaded" color="green-7" text-color="white" dense size="sm" icon="check">
              {{ m.sizeMb === null ? t("models.present") : `${m.sizeMb} MB` }}
            </q-chip>
            <q-chip v-else color="grey-7" text-color="white" dense size="sm">{{ t("models.missing") }}</q-chip>
          </td>
          <td class="text-right" style="white-space: nowrap">
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
            <span v-else class="text-caption text-grey-6" style="cursor: help; border-bottom: 1px dotted">
              {{ t("models.notDownloadable") }}
              <q-tooltip max-width="320px">{{ t("models.notDownloadableWhy") }}</q-tooltip>
            </span>
            <q-btn
              v-if="m.downloaded"
              dense
              flat
              round
              icon="delete"
              color="red-5"
              :disable="busy"
              @click="openDelete(m.id)"
            >
              <q-tooltip>{{ t("models.delete") }}</q-tooltip>
            </q-btn>
          </td>
        </tr>
      </tbody>
    </q-markup-table>
    <div class="text-caption text-grey-6 q-mt-sm">{{ t("models.pollNote") }}</div>

    <!-- Delete confirmation: dry-run preview, then force -->
    <q-dialog v-model="deleteOpen">
      <q-card class="bg-dark text-grey-3" style="min-width: 420px; max-width: 90vw">
        <q-card-section class="text-subtitle1">
          {{ t("models.deleteTitle", { id: deleteId }) }}
        </q-card-section>
        <q-card-section class="q-pt-none">
          <template v-if="preview">
            <div class="text-caption text-grey-5">{{ t("models.filesToDelete") }}:</div>
            <div v-if="previewFiles.length === 0" class="text-caption text-grey-6">—</div>
            <div
              v-for="f in previewFiles"
              :key="f"
              class="text-caption"
              style="font-family: monospace; word-break: break-all"
            >
              {{ f }}
            </div>
            <div v-if="previewExternal" class="text-caption text-amber-4 q-mt-sm">
              {{ t("models.externalKept", { dir: previewExternal }) }}
            </div>
            <div v-if="previewRefs.length > 0" class="text-caption text-orange-4 q-mt-sm">
              {{ t("models.referencingInstances") }}: {{ previewRefs.join(", ") }}
              <div>{{ t("models.cascadeNote") }}</div>
            </div>
          </template>
          <div v-else class="text-caption text-grey-6">{{ t("common.loading") }}</div>
        </q-card-section>
        <q-card-actions align="right">
          <q-btn flat :label="t('models.cancel')" color="grey-4" v-close-popup />
          <q-btn
            flat
            :label="t('models.confirmDelete')"
            color="red-5"
            :loading="busy"
            :disable="preview === null"
            @click="doDelete"
          />
        </q-card-actions>
      </q-card>
    </q-dialog>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue"
import { useI18n } from "vue-i18n"
import { deleteModel, downloadModel, fetchModels } from "src/services/api"
import type { ModelStatus } from "src/types"

const { t } = useI18n()

const models = ref<ModelStatus[]>([])
const error = ref<string | null>(null)
const busy = ref(false)
let timer: ReturnType<typeof setInterval> | undefined

const deleteOpen = ref(false)
const deleteId = ref("")
const preview = ref<Record<string, unknown> | null>(null)

const previewFiles = computed<string[]>(() => (preview.value?.files as string[] | undefined) ?? [])
const previewRefs = computed<string[]>(
  () => (preview.value?.referencing_instances as string[] | undefined) ?? [],
)
const previewExternal = computed<string | null>(
  () => (preview.value?.external_dir as string | null | undefined) ?? null,
)

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

const openDelete = async (id: string): Promise<void> => {
  error.value = null
  deleteId.value = id
  preview.value = null
  deleteOpen.value = true
  try {
    preview.value = await deleteModel(id, { dryRun: true })
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
    deleteOpen.value = false
  }
}

const doDelete = async (): Promise<void> => {
  busy.value = true
  error.value = null
  try {
    await deleteModel(deleteId.value, { force: true })
    deleteOpen.value = false
    await reload()
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  } finally {
    busy.value = false
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
