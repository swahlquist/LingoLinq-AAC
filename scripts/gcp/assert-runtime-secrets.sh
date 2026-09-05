#!/usr/bin/env bash
# assert-runtime-secrets.sh — fail closed when a live Cloud Run revision is missing a
# secret the deploy was supposed to mount.
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-04 a manual `gcloud run` deploy of `lingolinq-web` produced revision
# `00014`, which dropped exactly `BEDROCK_AWS_KEY` and `BEDROCK_AWS_SECRET` and nothing
# else. Cloud Run creates a new immutable revision on ANY config change, so a deploy that
# reuses the same image can still silently remove secrets. For ~54 minutes the Tier 1
# runtime AI credential path was absent from production and `AiClient.configured?` would
# have returned false, failing every AI feature closed. Nothing detected it; the gap was
# found only by reading revision history a day later.
#
# The deploy workflow already gates on secrets EXISTING in Secret Manager before it
# deploys (see the "verify secrets are seeded" step). That check cannot catch this class
# of bug: the secret containers were present and healthy the whole time. What was missing
# was the REFERENCE from the running revision to the secret. This script closes that gap
# by reading back what actually landed.
#
# WHAT IT CHECKS
# --------------
# For each named service/worker-pool, resolves every revision that is actually serving
# traffic (not merely the latest created) and asserts every required env var is present
# AND is backed by a `secretKeyRef`. A var that is present but downgraded to a literal
# value is treated as a failure: it means the secret linkage was replaced by something
# else. Under a canary/rollback split, every nonzero-percent target is checked so a
# minority revision cannot hide a dropped secret.
#
# SCOPE AND LIMITS — read before trusting this
# --------------------------------------------
# * Called from the deploy workflow, it makes a CI deploy that drops a secret fail loudly
#   instead of silently.
# * It does NOT prevent drift introduced OUTSIDE CI. The 00014 incident was a human
#   running `gcloud run deploy` directly, which never touches this workflow. Guarding
#   that requires either restricting Cloud Run update permission to the deploy service
#   account, or running this script on a schedule. Both are deliberately out of scope
#   here.
# * NOTE for anyone deploying lingolinq-web by hand: the deploy workflow pins traffic to
#   the revision it health-checked, which clears `latestRevision`. After any workflow run
#   has done that, your manual `gcloud run deploy` creates a revision serving 0% and still
#   exits 0 -- so this script can report a revision "clean" that nobody is using. Check
#   `gcloud run services describe lingolinq-web --region us-central1 --format='value(spec.traffic)'`
#   and shift traffic deliberately with `update-traffic --to-revisions <new>=100`.
#   Run it standalone any time to reconcile live state:
#
#     bash scripts/gcp/assert-runtime-secrets.sh \
#       --project lingolinq-prod --region us-central1 \
#       --service lingolinq-web --worker-pool lingolinq-worker \
#       --required "BEDROCK_AWS_KEY=x,BEDROCK_AWS_SECRET=x,SECRET_KEY_BASE=x"
#
# * It asserts the LINKAGE, not the value. It never reads secret material, and needs only
#   `run.revisions.get` / `run.workerPools.get`, not `secretmanager.secretAccessor`.
#
# --required accepts the same `NAME=SECRET:version,...` form as `gcloud --set-secrets`,
# so the workflow passes "$BOOT_SECRETS,$NON_BOOT_SECRETS" through unmodified and there is
# no second list to keep in sync. Only the NAME (left of `=`) is used.
set -euo pipefail

PROJECT=''; REGION=''; SERVICE=''; WORKER_POOL=''
REQUIRED_ITEMS=(); REQUIRED_LITERAL_ITEMS=()

# ARRAYS, NOT A COMMA-JOINED STRING. Three defects in three review rounds all traced to
# accumulating these into one comma-delimited string and re-splitting it later:
#   * assigning instead of appending kept only the LAST flag (round 2);
#   * an empty entry, or an entry with an empty NAME, vanished in the re-split and the
#     assertion silently disappeared (round 4);
#   * a comma is legal INSIDE an ERE -- `^(a|b){1,2}$` is a valid pattern -- so re-splitting
#     tore one assertion into two. That produced a FALSE PASS: `FOO=^a,BAR` became "FOO
#     matches ^a" plus "BAR is present", both of which can pass while the intended pattern
#     rejects FOO (round 4).
# An array holds each argument verbatim, so none of those are representable.
#
# --required still accepts a comma list inside ONE flag, because the workflow passes
# "$BOOT_SECRETS,$NON_BOOT_SECRETS" through unmodified in gcloud's own --set-secrets form,
# and a secret reference never contains a comma. --required-literal does NOT split: one
# flag is exactly one assertion, which is the only way an ERE can be passed intact.
while [ $# -gt 0 ]; do
  case "$1" in
    --project)     PROJECT="$2"; shift 2 ;;
    --region)      REGION="$2"; shift 2 ;;
    --service)     SERVICE="$2"; shift 2 ;;
    --worker-pool) WORKER_POOL="$2"; shift 2 ;;
    --required)
      [ -n "${2:-}" ] || { echo "assert-runtime-secrets: --required given an empty value" >&2; exit 2; }
      while IFS= read -r _field; do REQUIRED_ITEMS+=("$_field"); done < <(printf '%s\n' "$2" | tr ',' '\n')
      shift 2 ;;
    --required-literal)
      [ -n "${2:-}" ] || { echo "assert-runtime-secrets: --required-literal given an empty value" >&2; exit 2; }
      REQUIRED_LITERAL_ITEMS+=("$2")
      shift 2 ;;
    *) echo "assert-runtime-secrets: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# Validate every entry BEFORE anything strips or matches. An empty entry, or one whose NAME
# half is empty, is a caller mistake: silently dropping it is how an assertion the caller
# believes it made never runs.
for _item in ${REQUIRED_ITEMS[@]+"${REQUIRED_ITEMS[@]}"}; do
  [ -n "$_item" ] || { echo "assert-runtime-secrets: --required has an empty entry" >&2; exit 2; }
  case "$_item" in
    =*) echo "assert-runtime-secrets: --required entry '$_item' has an empty env var name" >&2; exit 2 ;;
  esac
done
for _item in ${REQUIRED_LITERAL_ITEMS[@]+"${REQUIRED_LITERAL_ITEMS[@]}"}; do
  case "$_item" in
    # No `=` at all is the deliberate present-and-non-empty form, handled at match time.
    *=*)
      [ -n "${_item%%=*}" ] || {
        echo "assert-runtime-secrets: --required-literal entry '$_item' has an empty env var name" >&2; exit 2; }
      [ -n "${_item#*=}" ] || {
        echo "assert-runtime-secrets: --required-literal entry '$_item' has an EMPTY pattern. An empty ERE matches any non-empty value, which would silently reduce this assertion to a presence check. Write the pattern, or pass the bare name '${_item%%=*}' if presence is what you mean." >&2
        exit 2; }
      ;;
  esac
done

[ -n "$PROJECT" ] || { echo "assert-runtime-secrets: --project is required" >&2; exit 2; }
[ -n "$REGION" ]  || { echo "assert-runtime-secrets: --region is required" >&2; exit 2; }
[ "$(( ${#REQUIRED_ITEMS[@]} + ${#REQUIRED_LITERAL_ITEMS[@]} ))" -gt 0 ] || {
  echo "assert-runtime-secrets: one of --required / --required-literal is required" >&2; exit 2; }
[ -n "$SERVICE$WORKER_POOL" ] || {
  echo "assert-runtime-secrets: at least one of --service / --worker-pool is required" >&2; exit 2; }

# Resolve every revision actually receiving traffic. `latestReadyRevisionName` alone is
# not enough: traffic can be pinned to an older revision, or split across several
# (canary / rollback). Emit one revision name per line for every status.traffic entry
# with percent > 0; fall back to latestReady only when no nonzero targets exist.
serving_revisions() {
  gcloud run services describe "$1" --project="$PROJECT" --region="$REGION" --format=json 2>/dev/null \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
st = d.get("status", {}) or {}
latest = st.get("latestReadyRevisionName") or ""
revs, seen = [], set()
for t in st.get("traffic", []) or []:
    pct = t.get("percent") or 0
    if pct <= 0:
        continue
    rev = t.get("revisionName") or (latest if t.get("latestRevision") else "")
    if rev and rev not in seen:
        seen.add(rev)
        revs.append(rev)
if not revs and latest:
    revs.append(latest)
for r in revs:
    print(r)
'
}

# Cloud Run services and worker pools do not share a response shape, and the worker-pool
# API is still beta, so the container block sits at a different depth. Walk the document
# for the first "containers" list rather than hard-coding either path; that keeps this
# working if the beta shape shifts before GA.
env_entries() {
  python3 -c '
import json, sys
d = json.load(sys.stdin)
def find(o):
    if isinstance(o, dict):
        if isinstance(o.get("containers"), list) and o["containers"]:
            return o["containers"]
        for v in o.values():
            r = find(v)
            if r: return r
    elif isinstance(o, list):
        for v in o:
            r = find(v)
            if r: return r
    return None
containers = find(d) or []
for c in containers:
    for e in c.get("env", []) or []:
        name = e.get("name")
        if not name:
            continue
        # secretKeyRef => linked to Secret Manager; anything else => a literal value.
        linked = "secret" if "valueFrom" in e else "literal"
        # Tab-separated: a literal value may contain spaces. Newlines are folded
        # so one entry stays one line for the awk readers below.
        value = "" if linked == "secret" else str(e.get("value", "")).replace("\n", " ").replace("\t", " ")
        print("%s\t%s\t%s" % (name, linked, value))
'
}

# Only the env-var NAME matters; strip the =SECRET:version half of each --set-secrets pair.
# Derived from the validated ARRAY, so an empty entry or an empty name cannot reach here --
# both are rejected at parse time above rather than silently filtered out.
mapfile -t REQUIRED_NAMES < <(
  for _i in ${REQUIRED_ITEMS[@]+"${REQUIRED_ITEMS[@]}"}; do printf '%s\n' "${_i%%=*}"; done | sort -u)
if [ "${#REQUIRED_ITEMS[@]}" -gt 0 ] && [ "${#REQUIRED_NAMES[@]}" -eq 0 ]; then
  echo "assert-runtime-secrets: --required parsed to zero names" >&2; exit 2
fi

# --required-literal is the NON-secret counterpart: `NAME=ERE,...`, where ERE is an
# extended regular expression the deployed VALUE must match. It exists because a
# control can be carried by a plain env var rather than a secret, and such a var has
# no readback anywhere else. BEDROCK_EXPECTED_AWS_ACCOUNT is the case in hand: it
# drives AiClient's BAA account assertion, and when it is absent that assertion is
# SKIPPED, so losing it silently disables a HIPAA control (finding LL-1b0d78dbe6).
#
# It cannot be folded into --required: that path FAILS on any var not backed by a
# secretKeyRef, and these are literals by design. The two lists are checked with
# opposite expectations about linkage, which is exactly why both are needed.
#
# Reading these values is safe and deliberate: a literal env var on a revision is
# not secret material, and this still needs only `run.revisions.get`. Values from
# secretKeyRef entries are never read -- env_entries emits an empty value for them.
# Verbatim, one element per flag. NOT re-split on commas: a comma is legal inside an ERE.
REQUIRED_LITERAL_PAIRS=(${REQUIRED_LITERAL_ITEMS[@]+"${REQUIRED_LITERAL_ITEMS[@]}"})

failed=0

# Assert required env vars on one already-fetched revision/worker-pool JSON document.
assert_env_json() {
  local label="$1" json="$2"
  if [ -z "$json" ]; then
    echo "FAIL [$label] could not read live configuration" >&2
    failed=1; return
  fi

  local entries missing=() literal=()
  entries="$(printf '%s' "$json" | env_entries)"

  local want
  for want in "${REQUIRED_NAMES[@]}"; do
    local line
    line="$(printf '%s\n' "$entries" | awk -F'\t' -v w="$want" '$1 == w {print $2; exit}')"
    if [ -z "$line" ]; then
      missing+=("$want")
    elif [ "$line" != secret ]; then
      literal+=("$want")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "FAIL [$label] missing secret-backed env var(s): ${missing[*]}" >&2
    failed=1
  fi
  if [ "${#literal[@]}" -gt 0 ]; then
    echo "FAIL [$label] env var(s) present but NOT backed by a secretKeyRef: ${literal[*]}" >&2
    failed=1
  fi
  if [ "${#REQUIRED_NAMES[@]}" -gt 0 ] && [ "${#missing[@]}" -eq 0 ] && [ "${#literal[@]}" -eq 0 ]; then
    echo "   OK: all ${#REQUIRED_NAMES[@]} required env vars are secret-backed"
  fi

  assert_literal_env "$label" "$entries"
}

# Assert every --required-literal NAME is present as a LITERAL value matching its ERE.
# A name that arrives secret-backed is a failure too: the value cannot be read back,
# so the pattern cannot be checked, so the control cannot be proven.
assert_literal_env() {
  local label="$1" entries="$2"
  # Say so out loud when there is nothing to check. A silent no-op inside the tool
  # built to detect silent no-ops is the one failure mode this script must not have:
  # `--required-literal ''` (e.g. an unset CI variable) would otherwise print OK.
  if [ "${#REQUIRED_LITERAL_PAIRS[@]}" -eq 0 ]; then
    echo "   note: no literal env assertions requested"
    return 0
  fi

  local pair name pattern row kind value ok=1
  for pair in "${REQUIRED_LITERAL_PAIRS[@]}"; do
    name="${pair%%=*}"
    pattern="${pair#*=}"
    # A bare NAME with no `=` means PRESENT AND NON-EMPTY, not bare presence: the default
    # pattern below is `.`, which requires at least one character, so a var deployed as the
    # empty string FAILS. That is deliberate and is what callers want (an empty value is how
    # a blank CI variable manifests), but it is not what the word "presence" implies on its
    # own, so the mode is named for what it actually checks.
    # Written as an `if` rather than `test && assign` because under `set -e` a failing
    # `a && b` statement aborts.
    if [ "$pattern" = "$pair" ]; then pattern='.'; fi

    row="$(printf '%s\n' "$entries" | awk -F'\t' -v w="$name" '$1 == w {print; exit}')"
    if [ -z "$row" ]; then
      echo "FAIL [$label] required literal env var is MISSING: $name" >&2
      ok=0; failed=1; continue
    fi

    kind="$(printf '%s' "$row" | cut -f2)"
    value="$(printf '%s' "$row" | cut -f3-)"
    if [ "$kind" != literal ]; then
      echo "FAIL [$label] $name is secret-backed; expected a literal whose value can be verified" >&2
      ok=0; failed=1; continue
    fi
    if ! printf '%s' "$value" | grep -Eq -- "$pattern"; then
      echo "FAIL [$label] $name='$value' does not match required pattern: $pattern" >&2
      ok=0; failed=1; continue
    fi
  done

  [ "$ok" -eq 1 ] && echo "   OK: all ${#REQUIRED_LITERAL_PAIRS[@]} required literal env var(s) present and well-formed"
  return 0
}

# Read one describe into $READ_JSON, converting a gcloud failure into a FAILED ASSERTION
# rather than an abort.
#
# WHY THIS IS NOT A PLAIN ASSIGNMENT. `json="$(gcloud ...)"` under `set -e` aborts the whole
# script the moment gcloud exits non-zero, and it aborts BEFORE the "could not read live
# configuration" guard in assert_env_json can run -- that guard is only reachable when gcloud
# exits 0 with empty stdout. The script then exits with gcloud's OWN code (proven: a stub
# exiting 9 produced rc=9 and no diagnostic), so a transient token refresh, an API 500 or a
# network blip becomes an undiagnosable red deploy in the worst possible window: the LAST step,
# after traffic has already shifted. A raw gcloud exit 2 would additionally masquerade as this
# script's documented usage-error code.
#
# Same class as the REMOTE_EXTRA_DATA over-pin: a benign external condition must not turn a
# healthy deploy red. Stderr is kept and surfaced, and the exit is this script's own 1.
READ_JSON=""
read_revision_json() {
  local label="$1"; shift
  local err rc=0
  err="$(mktemp)"
  READ_JSON="$("$@" 2>"$err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$label] could not read live configuration (gcloud exit $rc): $(tr '\n' ' ' < "$err" | cut -c1-300)" >&2
    rm -f "$err"; failed=1; READ_JSON=""; return 1
  fi
  rm -f "$err"
  return 0
}

check_target() {
  local kind="$1" name="$2" json rev
  if [ "$kind" = service ]; then
    local revs=()
    mapfile -t revs < <(serving_revisions "$name")
    if [ "${#revs[@]}" -eq 0 ] || [ -z "${revs[0]:-}" ]; then
      echo "FAIL [$name] could not resolve a serving revision" >&2
      failed=1; return
    fi
    for rev in "${revs[@]}"; do
      echo "== $name (serving revision: $rev)"
      read_revision_json "$name/$rev" gcloud run revisions describe "$rev" \
        --project="$PROJECT" --region="$REGION" --format=json || continue
      assert_env_json "$name/$rev" "$READ_JSON"
    done
  else
    echo "== $name (worker pool)"
    if read_revision_json "$name" gcloud beta run worker-pools describe "$name" \
         --project="$PROJECT" --region="$REGION" --format=json; then
      assert_env_json "$name" "$READ_JSON"
    fi
  fi
}

[ -n "$SERVICE" ]     && check_target service "$SERVICE"
[ -n "$WORKER_POOL" ] && check_target worker  "$WORKER_POOL"

if [ "$failed" -ne 0 ]; then
  cat >&2 <<'EOM'

Deployment is NOT safe: the live configuration is missing at least one secret the deploy
was supposed to mount. A revision in this state runs with the secret simply absent from
the environment, so any feature gated on it fails closed with no error at deploy time.
Redeploy with the full --set-secrets list ("$BOOT_SECRETS,$NON_BOOT_SECRETS"); a partial
--set-secrets REPLACES the whole set rather than merging into it.
EOM
  exit 1
fi

echo "assert-runtime-secrets: OK"
