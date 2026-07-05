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
        <div class="text-subtitle1 q-mb-sm">{{ t("daemons.title") }}</div>
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
            </tr>
          </thead>
          <tbody>
            <tr v-for="d in daemons" :key="d.name">
              <td class="text-left">
                <q-icon :name="d.kind === 'orchestrator' ? 'hub' : 'dns'" size="18px" color="grey-5">
                  <q-tooltip>{{ t(`kinds.${d.kind === 'orchestrator' ? 'orchestrator' : 'wsDaemon'}`) }}</q-tooltip>
                </q-icon>
              </td>
              <td class="text-left">{{ d.name }}</td>
              <td class="text-left">{{ d.modelName ?? "—" }}</td>
              <td class="text-left">{{ d.engine ?? "—" }}</td>
              <td class="text-left">{{ d.language ?? "—" }}</td>
              <td class="text-left">{{ d.host }}:{{ d.port }}</td>
              <td class="text-left">
                <q-chip :color="statusColor(d)" text-color="white" dense size="sm">
                  {{ t(`daemons.${d.detail}`) }}
                </q-chip>
              </td>
              <td class="text-right">{{ d.pid ?? "—" }}</td>
              <td class="text-right">{{ ageText(d.ageMs) }}</td>
            </tr>
            <tr v-if="daemons.length === 0">
              <td colspan="9" class="text-center text-grey-5">{{ t("daemons.empty") }}</td>
            </tr>
          </tbody>
        </q-markup-table>
      </q-tab-panel>

      <!-- Settings (editable) -->
      <q-tab-panel name="settings" class="q-pa-none">
        <SettingsForm />
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
              <td class="text-left"><pre class="cfg-value">{{ row.value }}</pre></td>
            </tr>
          </tbody>
        </q-markup-table>
      </q-tab-panel>
    </q-tab-panels>
  </q-page>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from "vue"
import { useI18n } from "vue-i18n"
import { fetchConfig, fetchDaemons } from "src/services/api"
import type { DaemonStatus } from "src/types"
import SettingsForm from "components/SettingsForm.vue"

const { t } = useI18n()

const tab = ref("daemons")
const loading = ref(false)
const error = ref<string | null>(null)
const daemons = ref<DaemonStatus[]>([])
const config = ref<Record<string, unknown>>({})

const configRows = computed(() =>
  Object.entries(config.value).map(([key, value]) => ({
    key,
    value: typeof value === "object" && value !== null ? JSON.stringify(value, null, 2) : String(value),
  })),
)

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

onMounted(reload)
</script>

<style scoped>
.cfg-value {
  margin: 0;
  white-space: pre-wrap;
  word-break: break-word;
  font-size: 12px;
  color: #cbd5e1;
}
</style>
