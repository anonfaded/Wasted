import { build } from "esbuild";
import { access, copyFile, mkdir } from "node:fs/promises";

async function exists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

if (!(await exists("config.js"))) {
  await copyFile("config.example.js", "config.js");
  console.log("Created web/config.js from config.example.js. Fill in your project URL/key.");
}

await mkdir("assets", { recursive: true });
await build({
  entryPoints: ["src/main.js"],
  bundle: true,
  format: "esm",
  outfile: "assets/app.js",
  sourcemap: true,
  target: ["es2020"],
});
console.log("Built web/assets/app.js for local source testing.");
