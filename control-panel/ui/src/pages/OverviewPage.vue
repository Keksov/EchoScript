<template>
  <q-page class="q-pa-md" style="max-width: 1000px; margin: 0 auto">
    <div class="row items-center q-mb-md">
      <q-tabs
        v-model="tab"
        dense
        class="text-grey-4"
        active-color="cyan-3"
        indicator-color="cyan-3"
        align="left"
      >
        <q-tab name="daemons" icon="dns" :label="t('tabs.services')" />
        <q-tab name="settings" icon="tune" :label="t('settings.title')" />
        <q-tab name="models" icon="model_training" :label="t('models.title')" />
        <q-tab name="config" icon="data_object" :label="t('tabs.config')" />
      </q-tabs>
      <q-space />
      <q-btn
        flat
        dense
        round
        icon="refresh"
        :loading="loading"
        :title="t('common.refresh')"
        @click="reload"
      />
    </div>

    <q-banner v-if="error" class="bg-red-9 text-white q-mb-md" rounded>
      {{ t("common.error") }}: {{ error }}
    </q-banner>

    <q-tab-panels v-model="tab" animated class="bg-transparent">
      <!-- Daemons -->
      <q-tab-panel name="daemons" class="q-pa-none">
        <div class="row items-center q-mb-sm">
          <div class="text-subtitle1">{{ t("daemons.title") }}</div>
          <q-space />
          <q-btn dense flat icon="add" :label="t('fleet.add')" color="cyan-3" @click="openAdd" />
        </div>
        <q-markup-table flat bordered dense class="bg-dark">
          <thead>
            <tr>
              <th class="text-left" style="width: 32px"></th>
              <th class="text-left">{{ t("daemons.name") }}</th>
              <th class="text-left">{{ t("daemons.model") }}</th>
              <th class="text-left">{{ t("daemons.engine") }}</th>
              <th class="text-left">{{ t("daemons.language") }}</th>
              <th class="text-left">{{ t("daemons.endpoint") }}</th>
              <th class="text-left">{{ t("daemons.state") }}</th>
              <th class="text-right">{{ t("daemons.pid") }}</th>
              <th class="text-right">{{ t("daemons.age") }}</th>
              <th class="text-right">{{ t("daemons.actions") }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="d in daemons" :key="d.name">
              <td class="text-left">
                <q-icon :name="kindIcon(d.kind)" size="18px" color="grey-5">
                  <q-tooltip>{{ t(`kinds.${kindKey(d.kind)}`) }}</q-tooltip>
                </q-icon>
              </td>
              <td class="text-left">{{ d.name }}</td>
              <td class="text-left">{{ d.modelName ?? "—" }}</td>
              <td class="text-left">{{ d.engine ?? "—" }}</td>
              <td class="text-left">{{ d.language ?? "—" }}</td>
              <td class="text-left">{{ d.host }}:{{ d.port }}</td>
              <td class="text-left">
                <q-chip
                  :color="statusColor(d)"
                  :text-color="d.detail === 'stale' ? undefined : 'white'"
                  :style="d.detail === 'stale' ? 'color: #0c55c7' : undefined"
                  dense size="sm"
                >
                  {{ t(`daemons.${d.detail}`) }}
                </q-chip>
              </td>
              <td class="text-right">{{ d.pid ?? "—" }}</td>
              <td class="text-right">{{ ageText(d.ageMs) }}</td>
              <td class="text-right" style="white-space: nowrap">
                <q-spinner v-if="busyService === d.name" size="18px" color="cyan-3" />
                <template v-else-if="d.controllable">
                  <q-btn
                    flat dense round size="sm" icon="play_arrow" color="green-5"
                    :disable="busyService !== null" @click="doAction(d.name, 'start')"
                  >
                    <q-tooltip>{{ t("daemons.start") }}</q-tooltip>
                  </q-btn>
                  <q-btn
                    flat dense round size="sm" icon="stop" color="red-5"
                    :disable="busyService !== null" @click="doAction(d.name, 'stop')"
                  >
                    <q-tooltip>{{ t("daemons.stop") }}</q-tooltip>
                  </q-btn>
                  <q-btn
                    flat dense round size="sm" icon="restart_alt" color="amber-5"
                    :disable="busyService !== null" @click="doAction(d.name, 'restart')"
                  >
                    <q-tooltip>{{ t("daemons.restart") }}</q-tooltip>
                  </q-btn>
                  <q-btn
                    v-if="d.kind === 'ws-daemon'"
                    flat dense round size="sm" icon="tune" color="cyan-4"
                    :disable="busyService !== null" @click="openEdit(d)"
                  >
                    <q-tooltip>{{ t("fleet.edit") }}</q-tooltip>
                  </q-btn>
                  <q-btn
                    v-if="d.kind === 'ws-daemon'"
                    flat dense round size="sm" icon="delete" color="red-5"
                    :disable="busyService !== null" @click="doRemove(d.name)"
                  >
                    <q-tooltip>{{ t("fleet.remove") }}</q-tooltip>
                  </q-btn>
                </template>
              </td>
            </tr>
            <tr v-if="daemons.length === 0">
              <td colspan="10" class="text-center text-grey-5">{{ t("daemons.empty") }}</td>
            </tr>
          </tbody>
        </q-markup-table>
      </q-tab-panel>

      <!-- Settings (editable) -->
      <q-tab-panel name="settings" class="q-pa-none">
        <SettingsForm />
      </q-tab-panel>

      <!-- Models (provisioning) -->
      <q-tab-panel name="models" class="q-pa-none">
        <ModelsTab />
      </q-tab-panel>

      <!-- Config (read-only) -->
      <q-tab-panel name="config" class="q-pa-none">
        <div class="text-subtitle1">{{ t("config.title") }}</div>
        <div class="text-caption text-grey-5 q-mb-sm">{{ t("config.hint") }}</div>
        <q-markup-table flat bordered dense class="bg-dark">
          <thead>
            <tr>
              <th class="text-left">{{ t("config.key") }}</th>
              <th class="text-left">{{ t("config.value") }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="row in configRows" :key="row.key">
              <td class="text-left text-cyan-3" style="vertical-align: top; white-space: nowrap">
                {{ row.key }}
              </td>
              <td class="text-left"><pre class="cfg-value" v-html="highlightJson(row.value)"></pre></td>
            </tr>
          </tbody>
        </q-markup-table>
      </q-tab-panel>
    </q-tab-panels>

    <DaemonForm
      v-model:open="daemonFormOpen"
      :mode="daemonFormMode"
      :instance="daemonFormInstance"
      :models="models"
      :daemon-fields="daemonFields"
      @saved="reload"
    />
  </q-page>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from "vue"
import { useI18n } from "vue-i18n"
import {
  controlService,
  fetchConfig,
  fetchDaemons,
  fetchModels,
  fetchSchema,
  removeDaemon,
} from "src/services/api"
import type { DaemonStatus, FieldSpec, ModelStatus, ServiceAction } from "src/types"
import SettingsForm from "components/SettingsForm.vue"
import ModelsTab from "components/ModelsTab.vue"
import DaemonForm from "components/DaemonForm.vue"

const { t } = useI18n()

const tab = ref("daemons")
const loading = ref(false)
const error = ref<string | null>(null)
const daemons = ref<DaemonStatus[]>([])
const config = ref<Record<string, unknown>>({})
const models = ref<ModelStatus[]>([])
const daemonFields = ref<FieldSpec[]>([])
const daemonFormOpen = ref(false)
const daemonFormMode = ref<"add" | "edit">("add")
const daemonFormInstance = ref<DaemonStatus | null>(null)

const configRows = computed(() =>
  Object.entries(config.value).map(([key, value]) => ({
    key,
    value: typeof value === "object" && value !== null ? JSON.stringify(value, null, 2) : String(value),
  })),
)

// Minimal dependency-free JSON syntax highlighter (CSP-safe): escape HTML, then wrap
// tokens in colour classes. Used via v-html on the read-only Config tab.
const highlightJson = (text: string): string => {
  const escaped = text
    .replace(/&/gu, "&amp;")
    .replace(/</gu, "&lt;")
    .replace(/>/gu, "&gt;")
  return escaped.replace(
    /("(?:\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(?:\s*:)?|\b(?:true|false)\b|\bnull\b|-?\d+(?:\.\d*)?(?:[eE][+-]?\d+)?)/gu,
    (match) => {
      let cls = "j-num"
      if (match.startsWith('"')) {
        cls = match.trimEnd().endsWith(":") ? "j-key" : "j-str"
      } else if (match === "true" || match === "false") {
        cls = "j-bool"
      } else if (match === "null") {
        cls = "j-null"
      }
      return `<span class="${cls}">${match}</span>`
    },
  )
}

const kindIcon = (kind: string): string =>
  kind === "orchestrator" ? "hub" : kind === "vosk-daemon" ? "record_voice_over" : "dns"

const kindKey = (kind: string): string =>
  kind === "orchestrator" ? "orchestrator" : kind === "vosk-daemon" ? "voskDaemon" : "wsDaemon"

const statusColor = (d: DaemonStatus): string => {
  if (d.up) return "green-7"
  if (d.detail === "orphan") return "orange-8"
  if (d.detail === "stale") return "amber-8"
  return "grey-7"
}

const ageText = (ageMs: number | null): string => {
  if (ageMs === null) return "—"
  const seconds = Math.round(ageMs / 1000)
  return seconds < 60 ? `${seconds}s` : `${Math.round(seconds / 60)}m`
}

const busyService = ref<string | null>(null)

const reload = async (): Promise<void> => {
  loading.value = true
  error.value = null
  try {
    const [d, c] = await Promise.all([fetchDaemons(), fetchConfig()])
    daemons.value = d
    config.value = c.config
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  } finally {
    loading.value = false
  }
}

const doAction = async (name: string, action: ServiceAction): Promise<void> => {
  busyService.value = name
  error.value = null
  try {
    const result = await controlService(name, action)
    if (!result.ok) {
      error.value = `${t("daemons.actionFailed")}: ${result.output}`
    }
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  } finally {
    busyService.value = null
    await reload()
  }
}

const openAdd = (): void => {
  daemonFormMode.value = "add"
  daemonFormInstance.value = null
  daemonFormOpen.value = true
}

const openEdit = (d: DaemonStatus): void => {
  daemonFormMode.value = "edit"
  daemonFormInstance.value = d
  daemonFormOpen.value = true
}

const doRemove = async (name: string): Promise<void> => {
  if (!window.confirm(t("fleet.removeConfirm", { name }))) return
  busyService.value = name
  error.value = null
  try {
    await removeDaemon(name)
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  } finally {
    busyService.value = null
    await reload()
  }
}

const loadAux = async (): Promise<void> => {
  try {
    const [ms, schema] = await Promise.all([fetchModels(), fetchSchema()])
    models.value = ms
    daemonFields.value = schema.wsDaemon.filter((f) => f.target === "daemon")
  } catch {
    // aux data is best-effort — the form still opens
  }
}

onMounted(() => {
  void reload()
  void loadAux()
})
</script>

<style scoped>
.cfg-value {
  margin: 0;
  white-space: pre-wrap;
  word-break: break-word;
  font-size: 12px;
  color: #cbd5e1;
}
.cfg-value :deep(.j-key) {
  color: #7dd3fc;
}
.cfg-value :deep(.j-str) {
  color: #86efac;
}
.cfg-value :deep(.j-num) {
  color: #fca5a5;
}
.cfg-value :deep(.j-bool) {
  color: #c4b5fd;
}
.cfg-value :deep(.j-null) {
  color: #94a3b8;
}
</style>
