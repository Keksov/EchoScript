<template>
  <q-dialog :model-value="open" @update:model-value="emit('update:open', $event)">
    <q-card class="bg-dark text-grey-3" style="min-width: 460px; max-width: 92vw">
      <q-card-section class="text-subtitle1">
        {{ mode === "add" ? t("fleet.addTitle") : t("fleet.editTitle", { name: instance?.name }) }}
      </q-card-section>

      <q-card-section class="q-gutter-sm q-pt-none">
        <template v-if="mode === 'add'">
          <q-select
            dense filled emit-value map-options
            v-model="engine"
            :options="engineOptions"
            :label="t('fields.engine.label')"
          />
          <q-input dense filled v-model="name" :label="t('daemons.name')" :hint="t('fleet.nameHint')" />
          <q-input
            v-if="engine !== 'diarization'"
            dense filled v-model="language" :label="t('fields.language.label')"
          />
        </template>

        <q-select
          dense filled emit-value map-options
          v-model="model"
          :options="modelOptions"
          :label="t('fields.model_name.label')"
        />
        <q-input
          dense filled type="number"
          v-model.number="port"
          :label="t('fields.port.label')"
          :hint="mode === 'add' ? t('fleet.portAuto') : ''"
        />

        <q-expansion-item dense :label="t('fleet.settings')" header-class="text-grey-4">
          <div class="q-pl-sm q-gutter-xs">
            <template v-for="f in daemonFields" :key="f.key">
              <q-toggle
                v-if="f.type === 'bool'"
                v-model="settings[f.key]"
                :label="t(`fields.${f.key}.label`)"
              />
              <q-input
                v-else
                dense filled type="number"
                v-model.number="settings[f.key]"
                :label="t(`fields.${f.key}.label`)"
                :hint="rangeHint(f)"
              />
            </template>
          </div>
        </q-expansion-item>
      </q-card-section>

      <q-card-section v-if="error" class="text-red-4 text-caption q-pt-none">{{ error }}</q-card-section>

      <q-card-actions align="right">
        <q-btn flat :label="t('models.cancel')" color="grey-4" @click="emit('update:open', false)" />
        <q-btn flat :label="t('common.save')" color="cyan-3" :loading="busy" @click="submit" />
      </q-card-actions>
    </q-card>
  </q-dialog>
</template>

<script setup lang="ts">
import { ref, computed, watch } from "vue"
import { useI18n } from "vue-i18n"
import { addDaemon, editDaemon } from "src/services/api"
import type { DaemonStatus, FieldSpec, ModelStatus } from "src/types"

const props = defineProps<{
  open: boolean
  mode: "add" | "edit"
  instance: DaemonStatus | null
  models: ModelStatus[]
  daemonFields: FieldSpec[]
}>()
const emit = defineEmits<{ "update:open": [boolean]; saved: [] }>()

const { t } = useI18n()

const engineOptions = [
  { label: "whisper", value: "whisper" },
  { label: "vosk", value: "vosk" },
  { label: "diarization", value: "diarization" },
]

const engine = ref("whisper")
const name = ref("")
const language = ref("")
const model = ref("")
const port = ref<number | null>(null)
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- dynamic form values (bool/number)
const settings = ref<Record<string, any>>({})
const busy = ref(false)
const error = ref<string | null>(null)

const modelOptions = computed(() =>
  props.models
    .filter((m) => m.modelName.length > 0 && (props.mode === "edit" || m.modelName.startsWith(engine.value)))
    .map((m) => ({ label: `${m.modelName} — ${m.model}`, value: m.modelName })),
)

const rangeHint = (f: FieldSpec): string =>
  f.min !== undefined || f.max !== undefined ? `${f.min ?? ""}..${f.max ?? ""}` : ""

// Switching engine (add mode) invalidates the model choice — models are engine-scoped;
// diarization is language-agnostic, so drop any typed language too.
watch(engine, () => {
  if (props.mode !== "add") return
  model.value = ""
  if (engine.value === "diarization") language.value = ""
})

// Reset the form whenever the dialog opens.
watch(
  () => props.open,
  (isOpen) => {
    if (!isOpen) return
    error.value = null
    settings.value = {}
    if (props.mode === "edit" && props.instance) {
      model.value = props.instance.modelName ?? ""
      port.value = props.instance.port
    } else {
      engine.value = "whisper"
      name.value = ""
      language.value = ""
      model.value = ""
      port.value = null
    }
  },
)

const collectSettings = (): Record<string, unknown> => {
  const out: Record<string, unknown> = {}
  for (const f of props.daemonFields) {
    const v = settings.value[f.key]
    if (v !== undefined && v !== null && v !== "") out[f.key] = v
  }
  return out
}

const submit = async (): Promise<void> => {
  busy.value = true
  error.value = null
  try {
    const body: Record<string, unknown> = {}
    if (model.value) body.model = model.value
    if (port.value !== null && port.value !== undefined) body.port = port.value
    const s = collectSettings()
    if (Object.keys(s).length > 0) body.settings = s

    if (props.mode === "add") {
      body.engine = engine.value
      if (name.value) body.name = name.value
      if (language.value) body.language = language.value
      await addDaemon(body)
    } else if (props.instance) {
      await editDaemon(props.instance.name, body)
    }
    emit("saved")
    emit("update:open", false)
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  } finally {
    busy.value = false
  }
}
</script>
