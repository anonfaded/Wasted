import { mkdir, readFile, writeFile } from "node:fs/promises";
import { renderDashboardHtml } from "./build-lib.mjs";

const html = await renderDashboardHtml({
  supabaseUrl: "__WASTED_SUPABASE_URL__",
  supabasePublishableKey: "__WASTED_PUBLISHABLE_KEY__",
  version: "__WASTED_VERSION__",
});

const headers = await readFile("_headers", "utf8");

await mkdir("../app/src/main/assets", { recursive: true });
await writeFile("../app/src/main/assets/dashboard-template.html", html);
await writeFile("../app/src/main/assets/dashboard_headers.txt", headers);
console.log("Built app/src/main/assets/dashboard-template.html and dashboard_headers.txt.");
