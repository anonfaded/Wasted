import { mkdir, rm, writeFile } from "node:fs/promises";
import { renderDashboardHtml } from "./build-lib.mjs";

await rm("dist", { recursive: true, force: true });
await mkdir("dist", { recursive: true });

const html = await renderDashboardHtml({
  supabaseUrl: "",
  supabasePublishableKey: "",
  version: "3.0.0",
});

await writeFile("dist/index.html", html);
console.log("Built dist/index.html. Add your project URL and publishable key to the CONFIG block, or use the app-generated file.");
