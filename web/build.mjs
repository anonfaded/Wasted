import { cp, mkdir, rm, writeFile } from "node:fs/promises";
import { renderDashboardHtml } from "./build-lib.mjs";

await rm("dist", { recursive: true, force: true });
await mkdir("dist", { recursive: true });

const html = await renderDashboardHtml({
  supabaseUrl: "",
  supabasePublishableKey: "",
  version: "3.0.0",
});

await writeFile("dist/index.html", html);
await cp("_headers", "dist/_headers");
console.log("Built dist/index.html and dist/_headers (header-capable hosts).");
