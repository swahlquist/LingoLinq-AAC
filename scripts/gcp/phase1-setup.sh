#!/usr/bin/env bash
#
# phase1-setup.sh - LingoLinq Render -> GCP Cloud Run migration, Phase 1 (Foundation).
#
# Stands up the lingolinq-prod GCP foundation so the inert PR #349 deploy workflow
# (.github/workflows/deploy-cloudrun.yml) can be activated in a later phase:
#   - the GCP project
#   - billing link            (MONEY GATE - opt-in)
#   - required APIs           (first billable-ish step - opt-in)
#   - least-privilege IAM (runtime SA, deploy SA, human team access)
#   - Workload Identity Federation (keyless GitHub Actions deploy, repo-locked)
#   - Artifact Registry repo `lingolinq`
#   - named (EMPTY) Secret Manager secrets the app needs (boot set + runtime app set)
#   - GitHub repo variables the workflow reads (GCP_PROJECT_ID deliberately deferred)
#
# It does NOT provision Cloud SQL, Memorystore, a VPC connector, or any Cloud Run
# service/job. Those are Phase 3+ (see the "PHASE 1 -> 3 HANDOFF" block at the end).
#
# Design rules:
#   - Idempotent: every create is guarded by a describe check, so re-runs are safe.
#   - Fail-closed gates: money/API/team-IAM steps run ONLY when their CONFIRM_* env
#     flag is set to 1. A bare run creates the (free) project and then stops at billing.
#   - Auditable: every command is commented with what it does and why (HIPAA evidence).
#
# Usage:
#   ./scripts/gcp/phase1-setup.sh                       # create project, stop at billing gate
#   CONFIRM_BILLING=1 ./scripts/gcp/phase1-setup.sh     # + link billing, stop at API gate
#   CONFIRM_BILLING=1 CONFIRM_APIS=1 ./scripts/gcp/phase1-setup.sh   # + APIs, IAM, WIF, AR, secrets
#   CONFIRM_TEAM_IAM=1 MELISSA_EMAIL=... DOMINIC_EMAIL=... ...       # + human team grants
#   SET_GH_VARS=1 ...                                   # + write GitHub repo variables (needs gh CLI)
#
set -euo pipefail

# ---------------------------------------------------------------------------------------
# CONFIG (override via env)
# ---------------------------------------------------------------------------------------
PROJECT_ID="${PROJECT_ID:-lingolinq-prod}"
PROJECT_NAME="${PROJECT_NAME:-LingoLinq Prod}"
REGION="${REGION:-us-central1}"
ORG_ID="${ORG_ID:-307791011610}"                       # lingolinq.com organization
BILLING_ACCOUNT="${BILLING_ACCOUNT:-0187AA-5B344F-C7E442}"  # the only account on this org

GH_REPO="${GH_REPO:-lingolinq/LingoLinq-AAC}"          # WIF is locked to THIS repo only
GH_OWNER_ID="${GH_OWNER_ID:-249911097}"                # immutable numeric id of the `lingolinq` org
GH_REPO_ID="${GH_REPO_ID:-1024104500}"                 # immutable numeric id of LingoLinq-AAC (survives rename)
AR_REPO="${AR_REPO:-lingolinq}"                        # MUST match deploy-cloudrun.yml image path

WIF_POOL="${WIF_POOL:-github-pool}"
WIF_PROVIDER="${WIF_PROVIDER:-github-provider}"

RUNTIME_SA_ID="lingolinq-run"                          # identity Cloud Run services/jobs run as
DEPLOY_SA_ID="cloud-run-deployer"                      # identity GitHub Actions impersonates (per PR #349)
RUNTIME_SA="${RUNTIME_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
DEPLOY_SA="${DEPLOY_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

# Gate flags (default 0 = do not run that gated step)
CONFIRM_BILLING="${CONFIRM_BILLING:-0}"
CONFIRM_APIS="${CONFIRM_APIS:-0}"
CONFIRM_TEAM_IAM="${CONFIRM_TEAM_IAM:-0}"
SET_GH_VARS="${SET_GH_VARS:-0}"

# Human team identities (required only when CONFIRM_TEAM_IAM=1)
MELISSA_EMAIL="${MELISSA_EMAIL:-}"
DOMINIC_EMAIL="${DOMINIC_EMAIL:-}"

# The boot secrets the web service, worker pool, AND migration Job all need (PR #349).
# Created here as EMPTY containers; values are seeded by hand from 1Password in Phase 2/3.
# DB connection uses discrete params (DB_HOST/DB_NAME/DB_USERNAME/DB_PASSWORD), NOT a DATABASE_URL:
# the Cloud SQL socket-form URL has an empty host that uri >= 1.0 rejects at boot.
BOOT_SECRETS=(
  SECRET_KEY_BASE
  COOKIE_KEY
  SECURE_ENCRYPTION_KEY
  SECURE_NONCE_KEY
  DB_HOST
  DB_NAME
  DB_USERNAME
  DB_PASSWORD
  REDIS_URL
  DEFAULT_HOST
  DEFAULT_EMAIL_FROM
  SYSTEM_ERROR_EMAIL
)

# The non-boot APP secrets the web service + worker need at RUNTIME (not at boot): S3/SES creds,
# Google/Stripe/AI/Sentry/SMS tokens, misc integration keys. Created here as EMPTY containers;
# values are seeded by scripts/gcp/phase4-seed-app-secrets.sh (Render-prod-first). The migration
# Job does NOT load these (it only needs the boot set), so they are NOT in the workflow's migrate
# step. These hold API keys / tokens only - NEVER PHI. (Migration env reconciliation 4.E1.)
# SMS_ENCRYPTION_KEY is preserve-exact (salts persisted RemoteTarget.source_hash); AWS_KEY/AWS_SECRET
# are a NEW least-privilege IAM user minted for Cloud Run (see scripts/gcp/iam/), NOT Render's key.
APP_SECRETS=(
  AWS_KEY
  AWS_SECRET
  GOOGLE_TTS_TOKEN
  GOOGLE_PLACES_TOKEN
  GOOGLE_TRANSLATE_TOKEN
  GOOGLE_OAUTH_CLIENT_ID
  GOOGLE_OAUTH_CLIENT_SECRET
  STRIPE_SECRET_KEY
  SENTRY_DSN
  SMS_ENCRYPTION_KEY
  INTERNAL_API_TOKEN
  CACHE_TOKEN
  OPENSYMBOLS_SECRET
  IPLOCATE_API_KEY
  YOUTUBE_API_KEY
)

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
skip() { printf '    \033[1;33m(skip)\033[0m %s\n' "$*"; }
gate() { printf '\n\033[1;31m[GATE]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------------------
# 0. PREFLIGHT - verify we are the right operator before touching anything
# ---------------------------------------------------------------------------------------
log "Preflight: verifying gcloud auth and org visibility"
ACTIVE_ACCT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
if [ -z "$ACTIVE_ACCT" ]; then
  echo "ERROR: no active gcloud account. Run: gcloud auth login && gcloud auth application-default login" >&2
  exit 1
fi
echo "    Active account: $ACTIVE_ACCT"
# Confirm the org is reachable (catches a stale/wrong login early).
gcloud organizations describe "$ORG_ID" --format='value(displayName)' >/dev/null \
  || { echo "ERROR: cannot see org $ORG_ID as $ACTIVE_ACCT" >&2; exit 1; }

# ---------------------------------------------------------------------------------------
# 1. [FREE] Create the project under the lingolinq.com org. Project creation costs $0.
# ---------------------------------------------------------------------------------------
log "Step 1: project $PROJECT_ID (under org $ORG_ID)"
if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
  skip "project $PROJECT_ID already exists"
else
  gcloud projects create "$PROJECT_ID" \
    --name="$PROJECT_NAME" \
    --organization="$ORG_ID"
fi
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
# Defensive: PROJECT_NUMBER feeds the security-sensitive WIF principalSet string below.
# Never let an empty value flow into an IAM member binding.
[ -n "$PROJECT_NUMBER" ] || { echo "ERROR: could not resolve project number for $PROJECT_ID" >&2; exit 1; }
echo "    Project number: $PROJECT_NUMBER"

# ---------------------------------------------------------------------------------------
# 2. [MONEY GATE] Link the billing account. Nothing billable can be enabled without this.
# ---------------------------------------------------------------------------------------
if [ "$CONFIRM_BILLING" != "1" ]; then
  gate "Step 2 SKIPPED. Linking billing account $BILLING_ACCOUNT is the MONEY GATE."
  gate "Re-run with CONFIRM_BILLING=1 once Scot approves. Stopping here."
  exit 0
fi
log "Step 2: link billing account $BILLING_ACCOUNT to $PROJECT_ID"
# Distinguish "not linked" (proceed) from a describe ERROR (abort) - do NOT blindly link
# on any non-zero exit, which would mask an auth/permission failure during the money step.
set +e
BILLING_ENABLED="$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null)"
BILLING_RC=$?
set -e
if [ "$BILLING_RC" -ne 0 ]; then
  echo "ERROR: could not read billing status for $PROJECT_ID (auth/permission?). Not linking." >&2
  exit 1
fi
if [ "$BILLING_ENABLED" = "True" ]; then
  skip "billing already enabled on $PROJECT_ID"
else
  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
fi

# ---------------------------------------------------------------------------------------
# 3. [API GATE] Enable the APIs Phase 1-3 need. Enabling is the first billable-ish action.
#    iam/iamcredentials/sts are required for WIF; serviceusage/resourcemanager for the rest.
#    compute.googleapis.com (VPC for Memorystore reachability) is deferred to Phase 3.
#    cloudbuild.googleapis.com is intentionally NOT enabled: the deploy workflow builds and
#    pushes images with `docker build`/`docker push` on the GitHub runner, not Cloud Build.
#    Enabling it would spin up an unused, broadly-privileged Cloud Build SA (least-privilege).
# ---------------------------------------------------------------------------------------
if [ "$CONFIRM_APIS" != "1" ]; then
  gate "Step 3 SKIPPED. Enabling APIs is the first billable-ish step."
  gate "Re-run with CONFIRM_BILLING=1 CONFIRM_APIS=1 once Scot approves. Stopping here."
  exit 0
fi
log "Step 3: enable required APIs"
gcloud services enable \
  run.googleapis.com \
  sqladmin.googleapis.com \
  redis.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="$PROJECT_ID"

# ---------------------------------------------------------------------------------------
# 4. [FREE] Service accounts. Two least-privilege identities, no keys ever downloaded.
#    - runtime SA: what Cloud Run services/jobs execute as
#    - deploy  SA: what GitHub Actions impersonates via WIF (PR #349 expects this exact email)
# ---------------------------------------------------------------------------------------
log "Step 4: service accounts (runtime + deploy)"
for pair in "$RUNTIME_SA_ID:LingoLinq Cloud Run runtime" "$DEPLOY_SA_ID:GitHub Actions Cloud Run deployer"; do
  sa_id="${pair%%:*}"; sa_desc="${pair#*:}"
  if gcloud iam service-accounts describe "${sa_id}@${PROJECT_ID}.iam.gserviceaccount.com" --project="$PROJECT_ID" >/dev/null 2>&1; then
    skip "service account ${sa_id} already exists"
  else
    gcloud iam service-accounts create "$sa_id" \
      --project="$PROJECT_ID" \
      --display-name="$sa_desc"
  fi
done

# ---------------------------------------------------------------------------------------
# 5. [FREE] IAM bindings - least privilege. NO Owner/Editor grants to anyone.
# ---------------------------------------------------------------------------------------
log "Step 5: IAM bindings (machine identities)"
# Deploy SA: deploy Cloud Run + push images. project-level.
# secretmanager.viewer (list/metadata, NOT value-read) lets the deploy workflow's "Assert referenced
# secrets exist" step probe every boot/app secret for an enabled version via `gcloud secrets versions
# list` WITHOUT granting it read access to the secret values (least privilege: only the runtime SA reads
# values). The build step still needs to READ two client-public build-arg secrets (MAPS_KEY,
# DEFAULT_HOST) -- those get scoped per-secret secretAccessor in Step 8 below, not a project-wide grant.
for role in roles/run.admin roles/artifactregistry.writer roles/secretmanager.viewer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${DEPLOY_SA}" --role="$role" --condition=None --quiet >/dev/null
done
# Deploy SA must actAs the runtime SA to deploy services/jobs that RUN as the runtime SA.
# Scoped to the runtime SA resource only (not project-wide serviceAccountUser).
gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/iam.serviceAccountUser" --condition=None --quiet >/dev/null
echo "    deploy SA -> run.admin, artifactregistry.writer, secretmanager.viewer, serviceAccountUser(on runtime SA)"
# NOTE (Phase 3): grant the RUNTIME SA roles/cloudsql.client once the Cloud SQL instance
# exists. Intentionally NOT granted here - see the handoff block. Redis needs no IAM (VPC).

# Human team access (gated: needs real identities + Scot's approval of the role map).
if [ "$CONFIRM_TEAM_IAM" = "1" ]; then
  log "Step 5b: human team IAM (least privilege)"
  if [ -n "$MELISSA_EMAIL" ]; then
    # Guard: only grant to @lingolinq.com identities. A valid-but-wrong address (personal
    # Gmail, typo) would otherwise get standing grants on a HIPAA/FERPA project with no
    # deprovisioning. (PR #353 adversary review; complements the deferred allowedPolicyMemberDomains.)
    case "$MELISSA_EMAIL" in *@lingolinq.com) ;; *) echo "ERROR: MELISSA_EMAIL ($MELISSA_EMAIL) is not an @lingolinq.com identity; refusing to grant." >&2; exit 1;; esac
    # Melissa - Rails/containerization/DB. Can deploy, push images, read logs and secret
    # METADATA (not values). No secretAccessor (cannot read prod values).
    # NOTE: Cloud SQL access is DEFERRED to Phase 3 and scoped to roles/cloudsql.client
    # (connect only) - NOT cloudsql.admin, which could delete the prod patient/student DB.
    # No Cloud SQL exists yet in Phase 1, so granting it now would be premature + over-broad.
    for role in roles/run.developer roles/artifactregistry.writer \
                roles/logging.viewer roles/monitoring.viewer roles/secretmanager.viewer; do
      gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="user:${MELISSA_EMAIL}" --role="$role" --condition=None --quiet >/dev/null
    done
    echo "    Melissa ($MELISSA_EMAIL) -> run.developer, artifactregistry.writer, logging/monitoring/secretmanager viewer (cloudsql.client deferred to Phase 3)"
  else
    skip "MELISSA_EMAIL unset - skipped Melissa grants"
  fi
  if [ -n "$DOMINIC_EMAIL" ]; then
    case "$DOMINIC_EMAIL" in *@lingolinq.com) ;; *) echo "ERROR: DOMINIC_EMAIL ($DOMINIC_EMAIL) is not an @lingolinq.com identity; refusing to grant." >&2; exit 1;; esac
    # Dominic - ops/DNS. DNS lives at the registrar, not GCP, so read-only observability only.
    for role in roles/logging.viewer roles/monitoring.viewer; do
      gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="user:${DOMINIC_EMAIL}" --role="$role" --condition=None --quiet >/dev/null
    done
    echo "    Dominic ($DOMINIC_EMAIL) -> logging.viewer, monitoring.viewer"
  else
    skip "DOMINIC_EMAIL unset - skipped Dominic grants"
  fi
else
  skip "Step 5b human team IAM skipped (set CONFIRM_TEAM_IAM=1 MELISSA_EMAIL=.. DOMINIC_EMAIL=..)"
fi

# ---------------------------------------------------------------------------------------
# 6. [FREE] Workload Identity Federation - keyless GitHub Actions deploy, LOCKED to one repo.
#    Security-critical, defense in depth:
#      (a) provider attribute-condition gates on the IMMUTABLE numeric repository_id AND
#          repository_owner_id (survive an org/repo rename or GitHub slug reuse - a slug-only
#          lock can be defeated if the org handle is ever released and re-registered), plus
#          the human-readable repository slug for auditability.
#      (b) the deploy SA's workloadIdentityUser is bound only to this repo's principalSet.
#    Without (a)+(b) an arbitrary GitHub repo could mint tokens that impersonate the deploy SA.
#    HARDENING DEFERRED to workflow-activation (Phase 2/3): also scope to a protected
#    deploy environment - add `environment: production` to the deploy job in
#    deploy-cloudrun.yml and bind the principalSet to attribute.environment/production
#    (with required reviewers). Not done here to avoid front-running the inert workflow's
#    design; tracked in the handoff block.
# ---------------------------------------------------------------------------------------
log "Step 6: Workload Identity Federation (locked to $GH_REPO)"
# Self-verify the hardcoded immutable ids actually match THIS repo before they become the
# WIF lock. If GH_REPO_ID/GH_OWNER_ID are wrong, the attribute-condition would admit the
# wrong repo and the slug-keyed principalSet becomes the only barrier - exactly the
# slug-reuse attack the immutable ids exist to defeat. (PR #353 adversary review.)
if command -v gh >/dev/null; then
  LIVE_REPO_ID="$(gh api "repos/${GH_REPO}" --jq '.id' 2>/dev/null || true)"
  LIVE_OWNER_ID="$(gh api "repos/${GH_REPO}" --jq '.owner.id' 2>/dev/null || true)"
  if [ -n "$LIVE_REPO_ID" ] && [ -n "$LIVE_OWNER_ID" ]; then
    if [ "$LIVE_REPO_ID" != "$GH_REPO_ID" ] || [ "$LIVE_OWNER_ID" != "$GH_OWNER_ID" ]; then
      echo "ERROR: WIF immutable-id mismatch for ${GH_REPO}." >&2
      echo "  configured: repo_id=$GH_REPO_ID owner_id=$GH_OWNER_ID" >&2
      echo "  live:       repo_id=$LIVE_REPO_ID owner_id=$LIVE_OWNER_ID" >&2
      echo "  Refusing to build a WIF lock on wrong ids. Fix GH_REPO_ID/GH_OWNER_ID." >&2
      exit 1
    fi
    echo "    Verified immutable ids match ${GH_REPO} (repo_id=$GH_REPO_ID owner_id=$GH_OWNER_ID)"
  else
    skip "could not reach gh api to verify repo ids - proceeding with configured constants"
  fi
else
  skip "gh CLI not found - cannot verify WIF immutable ids against the live repo"
fi
if gcloud iam workload-identity-pools describe "$WIF_POOL" \
     --project="$PROJECT_ID" --location=global >/dev/null 2>&1; then
  skip "WIF pool $WIF_POOL already exists"
else
  gcloud iam workload-identity-pools create "$WIF_POOL" \
    --project="$PROJECT_ID" --location=global \
    --display-name="GitHub Actions"
fi
# issuer = GitHub's OIDC endpoint; attribute-condition is the repo lock (immutable IDs).
# The describe-guard is create-only, but the attribute-condition is SECURITY-CRITICAL, so on
# re-run we RECONCILE it (update-oidc) rather than skip - otherwise a corrected condition
# would never reach an already-created provider and a stale/wrong lock would persist silently.
# (PR #353 adversary review - the "re-runs are safe" claim was overstated for this resource.)
WIF_MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_id=assertion.repository_id,attribute.repository_owner_id=assertion.repository_owner_id"
# BRANCH LOCK (2026-09-03; supersedes the prod-only hardcode from #918 / LL-1e7b568ef3, which
# would have written main-only onto the NONPROD provider on a re-run there).
# The repo lock alone lets ANY ref of this repo mint a deploy token,
# and this reconciler REPLACES the live condition on every re-run, so a repo-only condition here
# would silently erase the branch restriction deploy-cloudrun.yml relies on as safety gate 3
# (found by Codex review of PR #919). WIF_ALLOWED_REFS is the comma-separated list of refs the
# provider admits; the default is derived from PROJECT_ID so a re-run against a known project
# cannot widen the lock, and any other project must set it explicitly (fail closed).
#   lingolinq-prod    -> refs/heads/main
#   lingolinq-nonprod -> refs/heads/staging,refs/heads/develop
# deploy-cloudrun.yml's `resolve` map must agree with these lists; change them together.
# Remember whether the CALLER supplied this, before a default fills it in. The unknown-project
# gate below must distinguish "operator passed a list" from "script chose the default".
WIF_ALLOWED_REFS_EXPLICIT="${WIF_ALLOWED_REFS:-}"
case "${WIF_ALLOWED_REFS:-}" in
  "") case "$PROJECT_ID" in
        lingolinq-prod)    WIF_ALLOWED_REFS="refs/heads/main" ;;
        lingolinq-nonprod) WIF_ALLOWED_REFS="refs/heads/staging,refs/heads/develop" ;;
        *) echo "ERROR: WIF_ALLOWED_REFS is not set and PROJECT_ID=$PROJECT_ID has no default. Refusing to write a WIF condition without a branch lock." >&2; exit 1 ;;
      esac ;;
esac
# Validate the list before it becomes a security control. Two failure shapes this catches:
# a malformed entry (e.g. a stray space after a comma, which sed would quote INTO the literal and
# silently narrow the lock to a ref that can never match), and a caller widening a KNOWN project's
# lock via the environment. Without this the readback below compares the live value against the
# same intended string it just wrote and prints "verified" either way -- a check that cannot fail.
# Check the RAW string for whitespace FIRST. The per-entry loop below word-splits, which would
# silently absorb a stray space (e.g. "a, b") before any entry check could see it, while the
# renderer's `sed` would still quote that space INTO the literal and narrow the lock to a ref that
# can never match. Caught by testing the validator against that exact input rather than assuming.
case "$WIF_ALLOWED_REFS" in
  *[[:space:]]*) echo "ERROR: WIF_ALLOWED_REFS ('$WIF_ALLOWED_REFS') contains whitespace; use a comma-separated list with no spaces." >&2; exit 1 ;;
  *,,*|,*|*,) echo "ERROR: WIF_ALLOWED_REFS ('$WIF_ALLOWED_REFS') has an empty entry." >&2; exit 1 ;;
esac
for _ref in $(printf '%s' "$WIF_ALLOWED_REFS" | tr ',' ' '); do
  case "$_ref" in
    refs/heads/*) ;;
    *) echo "ERROR: WIF_ALLOWED_REFS entry '$_ref' is not a refs/heads/* branch ref." >&2; exit 1 ;;
  esac
  printf '%s' "$_ref" | grep -qE '^refs/heads/[A-Za-z0-9._/-]+$' \
    || { echo "ERROR: WIF_ALLOWED_REFS entry '$_ref' has illegal characters (or surrounding whitespace)." >&2; exit 1; }
done
# A known project may only use its own default unless the caller says explicitly that it means to
# change a live security control. WIF_ALLOWED_REFS alone cannot widen prod to another branch.
case "$PROJECT_ID" in
  lingolinq-prod|lingolinq-nonprod)
    case "$PROJECT_ID" in
      lingolinq-prod)    _expected="refs/heads/main" ;;
      lingolinq-nonprod) _expected="refs/heads/staging,refs/heads/develop" ;;
    esac
    if [ "$WIF_ALLOWED_REFS" != "$_expected" ] && [ "${CONFIRM_WIF_REF_CHANGE:-0}" != "1" ]; then
      echo "ERROR: refusing to set WIF_ALLOWED_REFS='$WIF_ALLOWED_REFS' on $PROJECT_ID (expected '$_expected')." >&2
      echo "  This is deploy-gate 3. Re-run with CONFIRM_WIF_REF_CHANGE=1 only if you intend to change it," >&2
      echo "  and update deploy-cloudrun.yml's branch map in the same change." >&2
      exit 1
    fi ;;
  *)
    # UNKNOWN PROJECT. An earlier review round argued this needed no gate, on the grounds that
    # an unknown project is a first-time bootstrap with no prior control to widen. That argument
    # is WRONG and was withdrawn: this script RECONCILES an existing provider with update-oidc
    # (see the describe/update branch below), so an unknown project id can perfectly well have a
    # live provider whose branch lock this run would rewrite. The gate therefore keys on what
    # actually matters -- whether a provider already exists -- not on whether the project is one
    # of the two hard-coded names.
    if [ -n "${WIF_ALLOWED_REFS_EXPLICIT:-}" ] && [ "${CONFIRM_WIF_REF_CHANGE:-0}" != "1" ]; then
      # DISTINGUISH "no provider" FROM "could not tell". Discarding stderr and treating every
      # non-zero exit as absent makes PERMISSION_DENIED, expired credentials, a disabled API and
      # a network failure indistinguishable from NOT_FOUND -- so the gate silently does not fire
      # and the run rewrites deploy-gate 3's branch lock unconfirmed. That is a fail-OPEN in a
      # block whose whole purpose is to fail closed. Only NOT_FOUND means absent; anything else
      # is an inconclusive probe and stops the run.
      _wif_probe_err="$(mktemp)"
      _wif_probe_rc=0
      gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
        --project "$PROJECT_ID" --location=global --workload-identity-pool="$WIF_POOL" \
        >/dev/null 2>"$_wif_probe_err" || _wif_probe_rc=$?
      if [ "$_wif_probe_rc" -eq 0 ]; then
        echo "ERROR: refusing to set WIF_ALLOWED_REFS='$WIF_ALLOWED_REFS' on $PROJECT_ID." >&2
        echo "  A workload-identity provider ALREADY EXISTS there, so this run would rewrite a live" >&2
        echo "  branch lock rather than bootstrap a new one. Re-run with CONFIRM_WIF_REF_CHANGE=1" >&2
        echo "  only if you intend to change it, and update deploy-cloudrun.yml's branch map in the" >&2
        echo "  same change." >&2
        rm -f "$_wif_probe_err"
        exit 1
      elif ! grep -qiE 'NOT_FOUND|was not found|does not exist' "$_wif_probe_err"; then
        echo "ERROR: could not determine whether a workload-identity provider already exists on" >&2
        echo "  $PROJECT_ID (gcloud exit $_wif_probe_rc). Refusing to set an explicit" >&2
        echo "  WIF_ALLOWED_REFS on an INCONCLUSIVE probe, because a permission or credential" >&2
        echo "  error would otherwise look identical to 'no provider' and silently skip this gate." >&2
        echo "  gcloud said: $(tr '\n' ' ' < "$_wif_probe_err" | cut -c1-300)" >&2
        rm -f "$_wif_probe_err"
        exit 1
      fi
      rm -f "$_wif_probe_err"
    fi ;;
esac
# Render the ref clause in the exact shape the live providers carry (verified 2026-09-03):
# one ref  -> assertion.ref == 'X' && assertion.ref_type == 'branch'
# several  -> assertion.ref_type == 'branch' && assertion.ref in ['A', 'B']
wif_ref_clause() {
  local list="$1" n first quoted
  n="$(printf '%s' "$list" | tr ',' '\n' | grep -c .)"
  if [ "$n" -eq 1 ]; then
    printf "assertion.ref == '%s' && assertion.ref_type == 'branch'" "$list"
  else
    quoted="$(printf '%s' "$list" | tr ',' '\n' | sed "s/.*/'&'/" | paste -sd, | sed 's/,/, /g')"
    printf "assertion.ref_type == 'branch' && assertion.ref in [%s]" "$quoted"
  fi
}
WIF_CONDITION="assertion.repository_owner_id == '${GH_OWNER_ID}' && assertion.repository_id == '${GH_REPO_ID}' && assertion.repository == '${GH_REPO}' && $(wif_ref_clause "$WIF_ALLOWED_REFS")"
echo "    WIF condition: repo lock + branch lock on [${WIF_ALLOWED_REFS}]"
if gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
     --project="$PROJECT_ID" --location=global --workload-identity-pool="$WIF_POOL" >/dev/null 2>&1; then
  echo "    reconciling existing WIF provider attribute-mapping + condition"
  gcloud iam workload-identity-pools providers update-oidc "$WIF_PROVIDER" \
    --project="$PROJECT_ID" --location=global \
    --workload-identity-pool="$WIF_POOL" \
    --attribute-mapping="$WIF_MAPPING" \
    --attribute-condition="$WIF_CONDITION"
else
  gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER" \
    --project="$PROJECT_ID" --location=global \
    --workload-identity-pool="$WIF_POOL" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="$WIF_MAPPING" \
    --attribute-condition="$WIF_CONDITION"
fi
# Bind the deploy SA's impersonation to ONLY this repo's principalSet.
gcloud iam service-accounts add-iam-policy-binding "$DEPLOY_SA" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GH_REPO}" \
  --quiet >/dev/null
WIF_PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}"
echo "    WIF provider: $WIF_PROVIDER_RESOURCE"
echo "    impersonation locked to principalSet .../attribute.repository/${GH_REPO}"
# Read back and assert: the live condition must be exactly what was intended, or stop here.
LIVE_COND="$(gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
  --project="$PROJECT_ID" --location=global --workload-identity-pool="$WIF_POOL" \
  --format='value(attributeCondition)')"
if [ "$LIVE_COND" != "$WIF_CONDITION" ]; then
  echo "ERROR: live WIF attribute-condition differs from the intended one." >&2
  echo "  intended: $WIF_CONDITION" >&2
  echo "  live:     $LIVE_COND" >&2
  exit 1
fi
echo "    verified live WIF condition == intended (repo + branch lock)"

# ---------------------------------------------------------------------------------------
# 7. [BILLABLE] Artifact Registry repo - name MUST be `lingolinq` (deploy-cloudrun.yml).
# ---------------------------------------------------------------------------------------
log "Step 7: Artifact Registry repo $AR_REPO ($REGION, docker)"
if gcloud artifacts repositories describe "$AR_REPO" \
     --project="$PROJECT_ID" --location="$REGION" >/dev/null 2>&1; then
  skip "Artifact Registry repo $AR_REPO already exists"
else
  gcloud artifacts repositories create "$AR_REPO" \
    --project="$PROJECT_ID" --location="$REGION" \
    --repository-format=docker \
    --description="LingoLinq Cloud Run container images"
fi
# Deploy SA pushes images; runtime SA pulls them.
gcloud artifacts repositories add-iam-policy-binding "$AR_REPO" \
  --project="$PROJECT_ID" --location="$REGION" \
  --member="serviceAccount:${DEPLOY_SA}" --role="roles/artifactregistry.writer" --quiet >/dev/null
gcloud artifacts repositories add-iam-policy-binding "$AR_REPO" \
  --project="$PROJECT_ID" --location="$REGION" \
  --member="serviceAccount:${RUNTIME_SA}" --role="roles/artifactregistry.reader" --quiet >/dev/null

# ---------------------------------------------------------------------------------------
# 8. [FREE] Secret Manager - create the boot + app secrets as EMPTY containers (names only).
#    No values here. Boot secrets are seeded by phase4-seed-boot-secrets.sh; the app secrets
#    by phase4-seed-app-secrets.sh (Render-prod-first). (App set added in migration 4.E1.)
#    Secrets are pinned to us-central1 (user-managed replication) for in-region auditability.
#    They hold API keys / connection strings only - NEVER PHI.
# ---------------------------------------------------------------------------------------
ALL_SECRETS=("${BOOT_SECRETS[@]}" "${APP_SECRETS[@]}")
log "Step 8: Secret Manager - ${#ALL_SECRETS[@]} named empty secrets (${#BOOT_SECRETS[@]} boot + ${#APP_SECRETS[@]} app) + runtime SA accessor"
for secret in "${ALL_SECRETS[@]}"; do
  if gcloud secrets describe "$secret" --project="$PROJECT_ID" >/dev/null 2>&1; then
    skip "secret $secret already exists"
  else
    gcloud secrets create "$secret" \
      --project="$PROJECT_ID" \
      --replication-policy="user-managed" \
      --locations="$REGION"
  fi
  # Runtime SA may READ values (least privilege: accessor only, scoped per-secret).
  gcloud secrets add-iam-policy-binding "$secret" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${RUNTIME_SA}" \
    --role="roles/secretmanager.secretAccessor" --quiet >/dev/null
done
echo "    Created/verified ${#ALL_SECRETS[@]} empty secrets (no versions yet)."

# Build-arg secrets: globals.js.erb bakes these into /assets/globals.js AT docker build
# (asset-precompile, see Dockerfile + deploy-cloudrun.yml "Build and push image"), so the DEPLOY SA
# (which runs the build) must READ them to pass --build-arg. They are CLIENT-PUBLIC (emitted to the
# browser as window.maps_key / window.default_host), never PHI. MAPS_KEY is build-only (no runtime
# mount, so it is NOT in ALL_SECRETS and gets no runtime-SA accessor); DEFAULT_HOST is also a boot
# secret (already created + runtime-accessor'd above), but the build needs deploy-SA read too.
BUILD_ARG_SECRETS=(MAPS_KEY DEFAULT_HOST)
for secret in "${BUILD_ARG_SECRETS[@]}"; do
  if ! gcloud secrets describe "$secret" --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud secrets create "$secret" \
      --project="$PROJECT_ID" \
      --replication-policy="user-managed" \
      --locations="$REGION"
  fi
  gcloud secrets add-iam-policy-binding "$secret" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${DEPLOY_SA}" \
    --role="roles/secretmanager.secretAccessor" --quiet >/dev/null
done
echo "    deploy SA -> secretAccessor on build-arg secrets: ${BUILD_ARG_SECRETS[*]} (client-public, build-time)"

# ---------------------------------------------------------------------------------------
# 9. [FREE] GitHub repo variables the workflow reads. GCP_PROJECT_ID is DELIBERATELY
#    omitted - setting it is the switch that un-inerts deploy-cloudrun.yml, which belongs
#    to Phase 2/3 readiness, not Phase 1. The Phase 3 vars (CLOUDSQL/VPC) are unknown yet.
# ---------------------------------------------------------------------------------------
if [ "$SET_GH_VARS" = "1" ]; then
  log "Step 9: set GitHub repo variables (gh CLI) - GCP_PROJECT_ID intentionally deferred"
  command -v gh >/dev/null || { echo "ERROR: gh CLI not found" >&2; exit 1; }
  # Guard: these vars retarget the LIVE repo's deploy workflow. Refuse to write them while
  # pointed at a non-prod project (e.g. PROJECT_ID overridden for a test run), which would
  # silently repoint prod CI at the wrong WIF provider/SA. (PR #353 adversary review.)
  if [ "$PROJECT_ID" != "lingolinq-prod" ] && [ "${ALLOW_NONPROD_GH_VARS:-0}" != "1" ]; then
    echo "ERROR: refusing to write GitHub repo vars while PROJECT_ID=$PROJECT_ID (not lingolinq-prod)." >&2
    echo "  Set ALLOW_NONPROD_GH_VARS=1 to override intentionally." >&2
    exit 1
  fi
  gh variable set GCP_REGION       --repo "$GH_REPO" --body "$REGION"
  gh variable set GCP_WIF_PROVIDER --repo "$GH_REPO" --body "$WIF_PROVIDER_RESOURCE"
  gh variable set GCP_DEPLOY_SA    --repo "$GH_REPO" --body "$DEPLOY_SA"
  echo "    Set GCP_REGION, GCP_WIF_PROVIDER, GCP_DEPLOY_SA. Did NOT set GCP_PROJECT_ID."
else
  skip "Step 9 GitHub repo vars skipped (set SET_GH_VARS=1 to write them via gh CLI)"
fi

# ---------------------------------------------------------------------------------------
# DONE - summary + PHASE 1 -> 3 HANDOFF (prerequisites flagged, NOT built here)
# ---------------------------------------------------------------------------------------
cat <<EOF

============================================================================
PHASE 1 FOUNDATION COMPLETE for ${PROJECT_ID} (project #${PROJECT_NUMBER})
============================================================================
Region:            ${REGION}
Runtime SA:        ${RUNTIME_SA}
Deploy SA:         ${DEPLOY_SA}
WIF provider:      ${WIF_PROVIDER_RESOURCE:-<not created - rerun past the API gate>}
Artifact Registry: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}
Secrets (empty):   boot: ${BOOT_SECRETS[*]}
                   app:  ${APP_SECRETS[*]}

GitHub repo vars to set (GCP_PROJECT_ID deferred until deploy-enable):
  GCP_REGION=${REGION}
  GCP_WIF_PROVIDER=${WIF_PROVIDER_RESOURCE:-<rerun>}
  GCP_DEPLOY_SA=${DEPLOY_SA}

*** BLOCKING PREREQUISITE before the deploy workflow is activated (review #353 H1) ***
  - deploy-cloudrun.yml MUST pass --service-account=${RUNTIME_SA} on ALL THREE deploy
    commands (gcloud run jobs deploy, run deploy lingolinq-web, run worker-pools deploy).
    Without it, Cloud Run runs as the DEFAULT COMPUTE SA (Editor), which (a) makes this
    script's runtime SA + all 9 per-secret accessor grants + the AR reader grant INERT,
    and (b) BREAKS BOOT - the default compute SA has no secretAccessor, so the app cannot
    read SECRET_KEY_BASE/DB_PASSWORD/etc. This is the runtime-identity contract for the
    whole least-privilege design; fix it in the workflow before any deploy.

PHASE 1 -> 3 HANDOFF (do NOT build now - Phase 3):
  - VPC + Serverless VPC connector / Direct VPC egress (Memorystore Redis reachability;
    Render Redis is NOT reachable from GCP). Enable compute.googleapis.com then.
  - Cloud SQL Postgres instance (zonal at launch) -> sets GCP_CLOUDSQL_INSTANCE
    (PROJECT:REGION:INSTANCE) for --set-cloudsql-instances.
  - Grant roles/cloudsql.client to ${RUNTIME_SA} once the instance exists.
  - DB-auth choice: password-over-socket vs IAM DB auth (drives the DB_* secret values).
  - VPC network/subnet -> GCP_VPC_NETWORK / GCP_VPC_SUBNET repo vars.
  - Worker pool has no autoscaling: --instances is a manual scaling control (ops runbook).
  - Secret Manager: seed the boot secrets (phase4-seed-boot-secrets.sh, 1Password-first) and
    the app secrets (phase4-seed-app-secrets.sh, Render-prod-first) before deploy.

SECURITY HARDENING TO APPLY WHEN THE DEPLOY WORKFLOW IS ACTIVATED (Phase 2/3):
  - Scope the WIF deploy identity to a protected GitHub environment: add
    'environment: production' (required reviewers) to the deploy job in
    deploy-cloudrun.yml, map attribute.environment, and bind the principalSet to
    .../attribute.environment/production instead of repo-wide. (adversary High #2)
  - Enable Data Access audit logs on Secret Manager + Cloud SQL for HIPAA evidence.
  - Set org policies: constraints/iam.disableServiceAccountKeyCreation (enforce the
    "no downloaded SA keys" convention) and constraints/iam.allowedPolicyMemberDomains
    (block grants to non-lingolinq.com identities). Deliberate org-level decision, not
    auto-applied here.
  - Default compute SA carries roles/editor on every new project (review #353 H2). Once
    the workflow uses ${RUNTIME_SA} (see BLOCKING prereq above), strip the default compute
    SA's Editor grant and/or set constraints/iam.automaticIamGrantsForDefaultServiceAccounts.
    Do it AFTER the --service-account fix, or the app (still running as compute SA) loses
    all permissions.

NOTE: this script only ADDS IAM grants (human + machine). Deprovisioning - revoking a
former teammate or rotating an SA - is a manual step; re-running with a changed
MELISSA_EMAIL/DOMINIC_EMAIL grants the new identity but does NOT revoke the old one.
EOF
