<template>
  <div>
    <q-banner v-if="error" class="bg-red-9 text-white q-mb-md" rounded>
      {{ t("common.error") }}: {{ error }}
    </q-banner>

    <q-banner v-if="restartNeeded" class="bg-amber-9 text-white q-mb-md" rounded>
      {{ t("settings.restartHint") }}
      <template #action>
        <q-btn
          flat
          dense
          :label="restarting ? t('settings.restarting') : t('settings.restartBtn')"
          :loading="restarting"
          @click="doRestart"
        />
      </template>
    </q-banner>

    <template v-if="schema">
      <!-- Orchestrator -->
      <div class="text-subtitle1 q-mb-xs">{{ t("settings.orchestrator") }}</div>
      <q-list bordered class="rounded-borders q-mb-lg">
        <q-item v-for="spec in schema.orchestrator" :key="spec.key">
          <q-item-section>
            <q-item-label>
              {{ t(`fields.${spec.key}.label`) }}
              <q-badge
                :color="spec.reload === 'restart' ? 'amber-8' : 'blue-grey-7'"
                class="q-ml-sm"
                :label="spec.reload === 'restart' ? t('settings.restartBadge') : t('settings.hotBadge')"
              />
            </q-item-label>
            <q-item-label caption class="text-grey-5">{{ t(`fields.${spec.key}.desc`) }}</q-item-label>
          </q-item-section>
          <q-item-section side style="min-width: 260px">
            <q-select
              v-if="spec.type === 'select'"
              v-model="orch[spec.key]"
              :options="modelOptions"
              dense
              outlined
              options-dense
            />
            <q-input
              v-else
              v-model="orch[spec.key]"
              :type="spec.type === 'int' ? 'number' : 'text'"
              dense
              outlined
            />
          </q-item-section>
        </q-item>
      </q-list>

      <!-- ws_daemons -->
      <div class="text-subtitle1 q-mb-xs">{{ t("settings.wsDaemons") }}</div>
      <div class="text-caption text-grey-5 q-mb-sm">{{ t("settings.daemonRestartNote") }}</div>
      <q-list bordered class="rounded-borders q-mb-lg">
        <template v-for="(fields, name) in ws" :key="name">
          <q-item-label header class="text-cyan-3">{{ name }}</q-item-label>
          <q-item v-for="spec in schema.wsDaemon" :key="`${name}.${spec.key}`">
            <q-item-section>
              <q-item-label>
                {{ t(`fields.${spec.key}.label`) }}
                <q-badge
                  :color="spec.reload === 'restart' ? 'amber-8' : 'blue-grey-7'"
                  class="q-ml-sm"
                  :label="spec.reload === 'restart' ? t('settings.restartBadge') : t('settings.hotBadge')"
                />
              </q-item-label>
              <q-item-label caption class="text-grey-5">{{ t(`fields.${spec.key}.desc`) }}</q-item-label>
            </q-item-section>
            <q-item-section side style="min-width: 260px">
              <q-toggle
                v-if="spec.type === 'bool'"
                :model-value="fields[spec.key] === '1'"
                dense
                @update:model-value="(v) => (fields[spec.key] = v ? '1' : '0')"
              />
              <q-input
                v-else
                v-model="fields[spec.key]"
                :type="spec.type === 'int' || spec.type === 'float' ? 'number' : 'text'"
                :step="spec.type === 'float' ? '0.05' : undefined"
                dense
                outlined
              />
            </q-item-section>
          </q-item>
        </template>
      </q-list>

      <div class="row q-gutter-sm">
        <q-btn color="cyan-8" :label="t('settings.save')" :loading="saving" @click="save" />
        <q-btn flat :label="t('settings.reset')" @click="reload" />
        <q-space />
        <div v-if="savedFlash" class="text-green-4 self-center">{{ t("settings.saved") }}</div>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { onMounted, reactive, ref } from "vue"
import { useI18n } from "vue-i18n"
import { fetchConfig, fetchSchema, restartOrchestrator, saveConfig } from "src/services/api"
import type { FieldSpec, SchemaResponse } from "src/types"

const { t } = useI18n()

const schema = ref<SchemaResponse | null>(null)
const orch = reactive<Record<string, string>>({})
const ws = reactive<Record<string, Record<string, string>>>({})
const modelOptions = ref<string[]>([])
const error = ref<string | null>(null)
const saving = ref(false)
const savedFlash = ref(false)
const restartNeeded = ref(false)
const restarting = ref(false)

// Form values are held as strings (q-input friendly; bool as "1"/"0"); coerced on save.
const coerce = (spec: FieldSpec, value: string): unknown => {
  if (spec.type === "bool") {
    return value === "1"
  }
  if (spec.type === "int") {
    const n = Number(value)
    return Number.isFinite(n) ? Math.trunc(n) : value
  }
  if (spec.type === "float") {
    const n = Number(value)
    return Number.isFinite(n) ? n : value
  }
  return value
}

// Load a config value into the string form model, falling back to the schema default.
const loadValue = (spec: FieldSpec, raw: unknown): string => {
  const value = raw === undefined || raw === null || raw === "" ? spec.default : raw
  if (spec.type === "bool") {
    return value === true || value === "1" || value === "true" ? "1" : "0"
  }
  return value === undefined || value === null ? "" : String(value)
}

const reload = async (): Promise<void> => {
  error.value = null
  try {
    const [sc, cfg] = await Promise.all([fetchSchema(), fetchConfig()])
    schema.value = sc
    const config = cfg.config
    for (const spec of sc.orchestrator) {
      orch[spec.key] = loadValue(spec, config[spec.key])
    }
    modelOptions.value =
      typeof config.models === "object" && config.models !== null
        ? Object.keys(config.models as Record<string, unknown>)
        : []
    const wsDaemons = (config.ws_daemons ?? {}) as Record<string, Record<string, unknown>>
    for (const key of Object.keys(ws)) delete ws[key]
    for (const [name, daemon] of Object.entries(wsDaemons)) {
      ws[name] = {}
      for (const spec of sc.wsDaemon) {
        ws[name]![spec.key] = loadValue(spec, daemon[spec.key])
      }
    }
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  }
}

const save = async (): Promise<void> => {
  if (schema.value === null) return
  saving.value = true
  error.value = null
  savedFlash.value = false
  try {
    const patch: Record<string, unknown> = {}
    for (const spec of schema.value.orchestrator) {
      patch[spec.key] = coerce(spec, orch[spec.key])
    }
    const wsPatch: Record<string, Record<string, unknown>> = {}
    for (const [name, fields] of Object.entries(ws)) {
      wsPatch[name] = {}
      for (const spec of schema.value.wsDaemon) {
        wsPatch[name]![spec.key] = coerce(spec, fields[spec.key])
      }
    }
    patch.ws_daemons = wsPatch
    const result = await saveConfig(patch)
    savedFlash.value = true
    if (result.restartRequired) restartNeeded.value = true
    setTimeout(() => (savedFlash.value = false), 2000)
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  } finally {
    saving.value = false
  }
}

const doRestart = async (): Promise<void> => {
  restarting.value = true
  error.value = null
  try {
    const result = await restartOrchestrator()
    if (result.ok) {
      restartNeeded.value = false
    } else {
      error.value = `${t("settings.restartFailed")}: ${result.output}`
    }
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  } finally {
    restarting.value = false
  }
}

onMounted(reload)
</script>
