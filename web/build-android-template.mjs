import { mkdir, writeFile } from "node:fs/promises";
import { renderDashboardHtml } from "./build-lib.mjs";

const html = await renderDashboardHtml({
  supabaseUrl: "__WASTED_SUPABASE_URL__",
  supabasePublishableKey: "__WASTED_PUBLISHABLE_KEY__",
  version: "__WASTED_VERSION__",
});

await mkdir("../app/src/main/assets", { recursive: true });
await writeFile("../app/src/main/assets/dashboard-template.html", html);
console.log("Built app/src/main/assets/dashboard-template.html (placeholder template).");
