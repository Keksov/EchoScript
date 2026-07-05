/* eslint-env node */

import { readFileSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const currentDir = dirname(fileURLToPath(import.meta.url))
const serverEnvPath = resolve(currentDir, "..", "server", "server.env")
const FALLBACK_SERVER_PORT = 3001

const parsePort = (value: string | undefined): number | null => {
  if (value === undefined) {
    return null
  }
  const port = Number(value.trim())
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    return null
  }
  return port
}

const readServerPortFromEnvFile = (): number | null => {
  try {
    const envText = readFileSync(serverEnvPath, "utf8")
    for (const line of envText.split(/\r?\n/u)) {
      const trimmedLine = line.trim()
      if (trimmedLine.length === 0 || trimmedLine.startsWith("#")) {
        continue
      }
      const separatorIndex = trimmedLine.indexOf("=")
      if (separatorIndex === -1) {
        continue
      }
      const key = trimmedLine.slice(0, separatorIndex).trim()
      const value = trimmedLine.slice(separatorIndex + 1).trim()
      if (key === "CONTROL_PANEL_PORT") {
        return parsePort(value)
      }
    }
    return null
  } catch {
    return null
  }
}

const resolveServerPort = (): number => {
  return parsePort(process.env.PORT)
    ?? parsePort(process.env.CONTROL_PANEL_PORT)
    ?? readServerPortFromEnvFile()
    ?? FALLBACK_SERVER_PORT
}

const serverProxyTarget = `http://localhost:${resolveServerPort()}`

export default function () {
  return {
    boot: ["i18n"],
    css: ["app.scss"],
    extras: ["material-icons"],
    build: {
      target: { browser: ["es2022"] },
      vueRouterMode: "hash",
      distDir: resolve(currentDir, "..", "server", "public"),
    },
    devServer: {
      open: false,
      proxy: {
        "/api": {
          target: serverProxyTarget,
        },
        "/ws": {
          target: serverProxyTarget,
          ws: true,
        },
      },
    },
    framework: {
      config: {
        dark: true,
      },
      iconSet: "material-icons",
    },
  }
}
