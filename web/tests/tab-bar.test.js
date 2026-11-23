import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const css = await readFile(new URL("../styles/main.css", import.meta.url), "utf8");
const main = await readFile(new URL("../src/main.js", import.meta.url), "utf8");

test("sticky tab bar docks below the measured header height, not a fixed guess", () => {
  assert.match(css, /--app-header-height:/);
  // Both the desktop sidebar and the mobile bar must use the shared variable.
  const uses = css.match(/top: (?:calc\()?var\(--app-header-height\)/g) ?? [];
  assert.ok(uses.length >= 2, "sidebar and mobile bar must both offset from the header");
  assert.doesNotMatch(css, /top: 5\.2rem/, "the old hardcoded sidebar offset must be gone");
  assert.doesNotMatch(css, /top: 4\.35rem/, "the old hardcoded mobile offset must be gone");
});

test("header height is measured at runtime so it survives reflow", () => {
  assert.match(main, /function trackHeaderHeight\(\)/);
  assert.match(main, /setProperty\("--app-header-height"/);
  assert.match(main, /new ResizeObserver\(apply\)\.observe\(header\)/);
  assert.match(main, /trackHeaderHeight\(\);/);
});

test("tab bar squares its top corners while docked to the header", () => {
  assert.match(css, /\.dashboard-nav\.is-stuck\s*\{[^}]*border-top-left-radius:\s*0/);
  assert.match(css, /\.dashboard-nav\.is-stuck\s*\{[^}]*border-top-right-radius:\s*0/);
  // Sticky has no CSS selector for "currently stuck", so it must be detected in script.
  assert.match(main, /function trackNavStuck\(\)/);
  assert.match(main, /classList\.toggle\("is-stuck", next\)/);
  assert.match(main, /trackNavStuck\(\);/);
});

test("stuck detection ignores the resting gap and hidden sections", () => {
  // Must compare against the resolved sticky offset, not the header's bottom edge,
  // otherwise the visual gap between them makes "docked" impossible to detect.
  assert.match(main, /parseFloat\(getComputedStyle\(nav\)\.top\)/);
  assert.match(main, /if \(!navRect\.height \|\| nav\.offsetParent === null\) return;/);
});

test("mobile tab bar spans the panel and centres its tabs", () => {
  const block = css.slice(css.indexOf("@media (max-width: 820px)"));
  const navRule = block.slice(block.indexOf(".dashboard-nav {"), block.indexOf(".dashboard-nav::-webkit-scrollbar"));
  assert.match(navRule, /width:\s*100%/, "the bar must fill the content width, not float");
  assert.match(navRule, /justify-content:\s*safe center/, "tabs must be centred without clipping on overflow");
  assert.doesNotMatch(navRule, /width:\s*fit-content/, "a shrink-wrapped bar reads as a floating pill");
});

test("the tab bar has real elevation (no malformed shadow shorthand)", () => {
  // A previous value expanded to "0 1px 0 0 1px 2px rgb(...)" and was discarded entirely.
  assert.doesNotMatch(css, /box-shadow:\s*0[^;]*var\(--shadow/);
  assert.match(css, /\.dashboard-nav\s*\{[^}]*box-shadow:\s*var\(--shadow-sm\)/);
});
