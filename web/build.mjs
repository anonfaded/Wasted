import { build } from "esbuild";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";

await rm("dist", { recursive: true, force: true });
await mkdir("dist", { recursive: true });

const bundle = await build({
  entryPoints: ["src/main.js"],
  bundle: true,
  format: "esm",
  minify: true,
  sourcemap: false,
  target: ["es2020"],
  write: false,
});

const js = bundle.outputFiles[0].text.replace(/<\/script/gi, "<\\/script");
const css = await readFile("styles/main.css", "utf8");
let html = await readFile("index.html", "utf8");

const configBlock = `<script>
  /* CONFIG - edit these values before deploying. Leave empty to see the setup banner. */
  window.WASTED_CONFIG = {
    supabaseUrl: "",
    supabasePublishableKey: "",
    productName: "Wasted Remote",
    version: "3.0.0",
    privacyUrl: "",
    supportUrl: "",
  };
</script>`;

// Replacement functions keep `$&`/`$1` sequences inside the bundle literal.
html = html.replace('<script src="config.js" defer></script>', () => configBlock);
html = html.replace('<link rel="stylesheet" href="styles/main.css">', () => `<style>\n${css}</style>`);
html = html.replace(
  '<script type="module" src="assets/app.js" defer></script>',
  () => `<script type="module">\n${js}</script>`,
);

await writeFile("dist/index.html", html);
console.log("Built dist/index.html (single-file dashboard). Edit the CONFIG block before deploying.");
