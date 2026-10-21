import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";

/**
 * Builds the user-facing SQL artifacts from the immutable migration history:
 *   - setup.sql for fresh projects (all migrations up to the current release)
 *   - updates/update-from-<old>-to-<current>.sql for stepwise app upgrades
 *   - updates/manifest.json with checksums and app/schema versions
 *
 * `releases.json` maps each app release to the cumulative migration list. Every migration on
 * disk must be covered exactly once, and each release's list must extend the previous one.
 */

const here = dirname(fileURLToPath(import.meta.url));
const repo = dirname(here);
const migrationsDir = join(here, "migrations");
const updatesDir = join(here, "updates");
const manifestPath = join(here, "releases.json");
const assetsDir = join(repo, "app", "src", "main", "assets");
const assetsUpdatesDir = join(assetsDir, "updates");

const releasesFile = JSON.parse(await readFile(manifestPath, "utf8"));
const diskMigrations = (await readdir(migrationsDir))
  .filter((name) => name.endsWith(".sql"))
  .sort();

const sorted = [...diskMigrations].sort();
if (JSON.stringify(diskMigrations) !== JSON.stringify(sorted)) {
  throw new Error("migrations directory is not sorted by filename");
}

const releases = [...releasesFile.releases].sort(
  (a, b) => a.schemaVersion - b.schemaVersion,
);
if (releases.length === 0) throw new Error("releases.json has no releases");

let previous = [];
for (const release of releases) {
  if (!release.appVersion || !Array.isArray(release.migrations)) {
    throw new Error("each release needs appVersion and migrations[]");
  }
  for (let index = 0; index < previous.length; index++) {
    if (release.migrations[index] !== previous[index]) {
      throw new Error(
        `${release.appVersion} must extend the previous release's migration list`,
      );
    }
  }
  for (const migration of release.migrations) {
    if (!diskMigrations.includes(migration)) {
      throw new Error(`${release.appVersion} references missing ${migration}`);
    }
  }
  previous = release.migrations;
}

if (JSON.stringify(previous) !== JSON.stringify(diskMigrations)) {
  throw new Error(
    "releases.json must cover every migration on disk exactly once; " +
      `manifest has ${previous.length}, disk has ${diskMigrations.length}`,
  );
}

const current = releases.find((release) => release.appVersion === releasesFile.current);
if (!current) throw new Error(`unknown current release ${releasesFile.current}`);
if (current !== releases[releases.length - 1]) {
  throw new Error("current release must be the newest schemaVersion");
}

function sha256(content) {
  return createHash("sha256").update(content).digest("hex");
}

function setupHeader() {
  return `-- Wasted Remote - one-time database setup for a FRESH Supabase project.
-- Paste this whole file into Supabase Dashboard -> SQL Editor -> Run.
-- Run it once. Do not run it again on an existing project and do not mix it with
-- "supabase db push" on the same project.
--
-- App release: ${current.appVersion} (schema ${current.schemaVersion})
--
-- This file configures the DATABASE (tables, RLS, RPCs, grants, Realtime, cron).
-- In Authentication settings (Dashboard -> Authentication):
--   1) enable "Allow anonymous sign-ins" (device identities)
--   2) disable "Confirm email" (instant owner account creation)
--   3) review the sign-up / sign-in rate limits
--
-- Extensions: pgcrypto is available on Supabase; pg_cron is enabled by the script.`;
}

function updateHeader(from, to) {
  return `-- Wasted Remote - database update for app ${from.appVersion} -> ${to.appVersion}
-- Schema ${from.schemaVersion} -> ${to.schemaVersion}.
--
-- Back up your Supabase project first (Database -> Backups, or supabase db dump).
-- Apply this file ONLY to a project that is already on ${from.appVersion}; never on a fresh
-- project (use setup.sql there) and never twice. Paste into SQL Editor -> Run.
-- Upgrades are stepwise: apply each release's update file in order.`;
}

function guard() {
  return `create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;`;
}

async function render(header, files) {
  const parts = [header, guard()];
  for (const file of files) {
    const sql = await readFile(join(migrationsDir, file), "utf8");
    parts.push(`-- ===== ${file} =====\n${sql.trim()}`);
  }
  parts.push("notify pgrst, 'reload schema';");
  return parts.join("\n\n") + "\n";
}

await rm(updatesDir, { recursive: true, force: true });
await rm(assetsUpdatesDir, { recursive: true, force: true });
await mkdir(updatesDir, { recursive: true });
await mkdir(assetsUpdatesDir, { recursive: true });
await mkdir(assetsDir, { recursive: true });

const setupSql = await render(setupHeader(), current.migrations);
await writeFile(join(here, "setup.sql"), setupSql);
await writeFile(join(assetsDir, "setup.sql"), setupSql);

const generatedUpdates = [];
for (const release of releases) {
  if (release === current) continue;
  const files = current.migrations.slice(release.migrations.length);
  if (files.length === 0) continue;

  const content = await render(updateHeader(release, current), files);
  const name = `update-from-${release.appVersion}-to-${current.appVersion}.sql`;
  await writeFile(join(updatesDir, name), content);
  await writeFile(join(assetsUpdatesDir, name), content);
  generatedUpdates.push({
    name,
    fromAppVersion: release.appVersion,
    toAppVersion: current.appVersion,
    fromSchemaVersion: release.schemaVersion,
    toSchemaVersion: current.schemaVersion,
    migrations: files,
    sha256: sha256(content),
  });
}

const manifest = {
  appVersion: current.appVersion,
  schemaVersion: current.schemaVersion,
  setupSha256: sha256(setupSql),
  updates: generatedUpdates,
};
await writeFile(
  join(updatesDir, "manifest.json"),
  JSON.stringify(manifest, null, 2) + "\n",
);

console.log(
  `Built supabase/setup.sql and ${generatedUpdates.length} update bundle(s) for ${current.appVersion}.`,
);
