import { Hono } from "hono";

const app = new Hono();

app.get("/", (c) => c.json({ service: "echoscript-orchestrator", status: "ok" }));

export default {
  port: 3000,
  fetch: app.fetch,
};
