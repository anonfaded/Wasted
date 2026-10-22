import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";

/**
 * Builds the user-facing SQL artifacts from the immutable migration history.
 *
 * Layout:
 *   supabase/migrations/                      flat, immutable, CLI-compatible developer history
 *   supabase/releases/<appVersion>/setup.sql  fresh-install baseline for that release
 *   supabase/releases/<appVersion>/update-*   stepwise upgrade bundles
 *   supabase/releases/<appVersion>/verify.sql post-install checks
 *   supabase/releases/<appVersion>/manifest.json
 *   supabase/releases/<appVersion>/README.md  generated apply instructions + checksums
 *   supabase/setup.sql                        alias of the current release baseline
 *   app/src/main/assets/setup.sql             bundled current baseline
 *   app/src/main/assets/updates/              bundled current upgrade bundles
 *
 * `releases.json` maps each app release to its cumulative migration list. Every migration on
 * disk must be covered exactly once, and each release's list must extend the previous one.
 */

const here = dirname(fileURLToPath(import.meta.url));
const repo = dirname(here);
const migrationsDir = join(here, "migrations");
const releasesDir = join(here, "releases");
const legacyUpdatesDir = join(here, "updates");
const manifestPath = join(here, "releases.json");
const verifyPath = join(here, "verify.sql");
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

function setupHeader(release) {
  return `-- Wasted Remote - one-time database setup for a FRESH Supabase project.
-- Paste this whole file into Supabase Dashboard -> SQL Editor -> Run.
-- Run it once. Do not run it again on an existing project and do not mix it with
-- "supabase db push" on the same project.
--
-- App release: ${release.appVersion} (schema ${release.schemaVersion})
--
-- This file configures the DATABASE (tables, RLS, RPCs, grants, Realtime, cron).
-- In Authentication settings (Dashboard -> Authentication):
--   1) enable "Allow anonymous sign-ins" (device identities)
--   2) leave "Confirm email" enabled (recommended; click the link, then sign in)
--   3) set the Auth Site URL to the hosted dashboard URL
--   4) review the sign-up / sign-in rate limits
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

function releaseReadme(release, updates, checksums) {
  const lines = [
    `# Wasted Remote SQL — ${release.appVersion}`,
    "",
    `Schema version: **${release.schemaVersion}**`,
    "",
    "Generated by `supabase/build-setup-sql.mjs` from the immutable migrations; do not edit.",
    "",
    "## Fresh install (new Supabase project only)",
    "",
    "1. Back up or export the project first if it contains anything you care about.",
    "2. Open **SQL Editor**, paste `setup.sql`, and press **Run** once.",
    "3. In **Authentication → Providers**: enable **Allow anonymous sign-ins** and",
    "   leave **Confirm email** enabled (recommended). Set **Authentication → URL Configuration**",
    "   **Site URL** to the hosted dashboard URL. Keep the default rate limits.",
    "4. Run `verify.sql`; every row must say PASS.",
    "",
    "Never run `setup.sql` on an existing project and never run it twice.",
    "",
    "## Upgrade from an earlier release",
    "",
  ];

  if (updates.length === 0) {
    lines.push("This is the initial release; there are no upgrade bundles.");
  } else {
    lines.push(
      "Back up first, apply the cumulative bundle matching your installed version, then run `verify.sql`.",
      "Each bundle contains every migration since its named release; no intermediate bundles are required.",
      "",
    );
    for (const update of updates) {
      lines.push(`- \`${update.name}\` — from ${update.fromAppVersion}`);
    }
  }

  lines.push("", "## Files", "", "| File | SHA-256 |", "| --- | --- |");
  for (const [name, hash] of Object.entries(checksums)) {
    lines.push(`| \`${name}\` | \`${hash}\` |`);
  }
  lines.push(
    "",
    "## Authentication checklist",
    "",
    "- Enable **Allow anonymous sign-ins** (per-device identities).",
    "- Leave **Confirm email** enabled (recommended; click the link, then sign in).",
    "- Set the Auth **Site URL** to the hosted dashboard URL.",
    "- Review sign-up/sign-in rate limits.",
    "- CAPTCHA is optional and not required by this project.",
    "",
  );
  return lines.join("\n");
}

await rm(releasesDir, { recursive: true, force: true });
await rm(legacyUpdatesDir, { recursive: true, force: true });
await rm(assetsUpdatesDir, { recursive: true, force: true });
await mkdir(releasesDir, { recursive: true });
await mkdir(assetsUpdatesDir, { recursive: true });
await mkdir(assetsDir, { recursive: true });

const verifySql = await readFile(verifyPath, "utf8");
const verifySha = sha256(verifySql);
const indexLines = [
  "# SQL releases",
  "",
  "Generated by `supabase/build-setup-sql.mjs` from `releases.json` and the immutable",
  "migrations. Do not edit by hand; run `node supabase/build-setup-sql.mjs`.",
  "",
  "| Release | Schema | Folder |",
  "| --- | --- | --- |",
];

let currentSetup = null;
const currentUpdateFiles = [];

for (const release of releases) {
  const folder = join(releasesDir, release.appVersion);
  await mkdir(folder, { recursive: true });

  const setupSql = await render(setupHeader(release), release.migrations);
  await writeFile(join(folder, "setup.sql"), setupSql);
  await writeFile(join(folder, "verify.sql"), verifySql);

  const updates = [];
  const checksums = {
    "setup.sql": sha256(setupSql),
    "verify.sql": verifySha,
  };

  for (const prior of releases) {
    if (prior === release) continue;
    const files = release.migrations.slice(prior.migrations.length);
    if (files.length === 0) continue;

    const content = await render(updateHeader(prior, release), files);
    const name = `update-from-${prior.appVersion}-to-${release.appVersion}.sql`;
    await writeFile(join(folder, name), content);
    updates.push({
      name,
      fromAppVersion: prior.appVersion,
      toAppVersion: release.appVersion,
      fromSchemaVersion: prior.schemaVersion,
      toSchemaVersion: release.schemaVersion,
      migrations: files,
      sha256: sha256(content),
    });
    checksums[name] = sha256(content);
  }

  await writeFile(join(folder, "README.md"), releaseReadme(release, updates, checksums));
  await writeFile(
    join(folder, "manifest.json"),
    JSON.stringify(
      {
        appVersion: release.appVersion,
        schemaVersion: release.schemaVersion,
        setupSha256: checksums["setup.sql"],
        verifySha256: verifySha,
        updates,
      },
      null,
      2,
    ) + "\n",
  );

  indexLines.push(
    `| ${release.appVersion} | ${release.schemaVersion} | [\`${release.appVersion}/\`](./${release.appVersion}/) |`,
  );

  if (release === current) {
    currentSetup = setupSql;
    for (const update of updates) {
      const content = await readFile(join(folder, update.name), "utf8");
      await writeFile(join(assetsUpdatesDir, update.name), content);
      currentUpdateFiles.push(update.name);
    }
  }
}

await writeFile(join(releasesDir, "README.md"), indexLines.join("\n") + "\n");

if (currentSetup === null) throw new Error("current release setup was not generated");
await writeFile(join(here, "setup.sql"), currentSetup);
await writeFile(join(assetsDir, "setup.sql"), currentSetup);

console.log(
  `Built ${releases.length} release folder(s), current ${current.appVersion} ` +
    `with ${currentUpdateFiles.length} update bundle(s).`,
);
