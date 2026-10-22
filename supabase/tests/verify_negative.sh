#!/usr/bin/env bash
# Negative verifier harness. Requires psql and a disposable database URL. Every drift case runs the
# real supabase/verify.sql after introducing drift; a PASS means verify.sql failed as expected.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${DATABASE_URL:?Set DATABASE_URL to a disposable PostgreSQL/Supabase connection}"

TMP_SQL="$(mktemp)"
trap 'rm -f "$TMP_SQL"' EXIT

run_failure_case() {
  local name="$1"
  local setup="$2"
  cat >"$TMP_SQL" <<SQL
begin;
$setup
\i '$ROOT/supabase/verify.sql'
rollback;
SQL
  if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$TMP_SQL" >/dev/null 2>&1; then
    echo "FAIL: $name — verify.sql did not reject the drift"
    exit 1
  fi
  echo "PASS: $name — verify.sql rejected the drift"
}

run_failure_case "extra permissive policy" \
  "create policy verify_extra on public.accounts as permissive for select to authenticated using (true);"

run_failure_case "mismatched policy predicate" \
  "drop policy accounts_select_owner on public.accounts; create policy accounts_select_owner on public.accounts for select to authenticated using (true);"

run_failure_case "PUBLIC default function grant" \
  "alter default privileges for role postgres grant execute on functions to public;"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$ROOT/supabase/verify.sql" >/dev/null
echo "PASS: undrifted database — verify.sql passed"
