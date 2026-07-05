import { boot } from "quasar/wrappers"
import { createI18n } from "vue-i18n"
import messages from "src/i18n"

export const LOCALE_STORAGE_KEY = "echoscript-cp-locale"
const DEFAULT_LOCALE = "ru"
const FALLBACK_LOCALE = "en"
export const SUPPORTED_LOCALES = new Set([DEFAULT_LOCALE, FALLBACK_LOCALE])

const resolveLocale = (): string => {
  try {
    const storedLocale = globalThis.localStorage?.getItem(LOCALE_STORAGE_KEY)
    if (storedLocale !== null && SUPPORTED_LOCALES.has(storedLocale)) {
      return storedLocale
    }
    return DEFAULT_LOCALE
  } catch {
    return DEFAULT_LOCALE
  }
}

export default boot(({ app }) => {
  const i18n = createI18n({
    legacy: false,
    locale: resolveLocale(),
    fallbackLocale: FALLBACK_LOCALE,
    messages,
  })

  app.use(i18n)
})
