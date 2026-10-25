#!/usr/bin/env bash
# Build the backend image and deploy it to Cloud Run.
#
#   ./deploy.sh              # build + deploy + smoke test
#   SKIP_BUILD=1 ./deploy.sh # redeploy the last built image (e.g. after changing env vars)
#
# Every setting can be overridden from the environment, e.g.
#   PROJECT=my-project BUCKET=my-bucket ./deploy.sh
#   ENV_FILE=~/elsewhere/.env ./deploy.sh
#
# The Gemini key is read at deploy time from $GEMINI_API_KEY, or else from
# GEMINI_API_KEY=... in $ENV_FILE (default: .env, which is gitignored), and set
# as a Cloud Run environment variable. Never put the key in this file: the repo
# is public.
set -euo pipefail

PROJECT="${PROJECT:-printbot-f7f6d}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-argonr-backend}"
BUCKET="${BUCKET:-argon-hackathon-models-383c2c}"
ENV_FILE="${ENV_FILE:-.env}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-argon-uploader@${PROJECT}.iam.gserviceaccount.com}"
GEMINI_MODEL="${GEMINI_MODEL:-gemini-4-argon}"
# One instance stays warm so the first request doesn't wait for a cold start.
# It is billed while idle; set MIN_INSTANCES=0 after the hackathon.
MIN_INSTANCES="${MIN_INSTANCES:-1}"
MAX_INSTANCES="${MAX_INSTANCES:-3}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/argonr/backend:latest"

cd "$(dirname "$0")"

# gcloud is often installed without being put on PATH.
GCLOUD="$(command -v gcloud || echo "$HOME/google-cloud-sdk/bin/gcloud")"
[[ -x "$GCLOUD" ]] || { echo "gcloud not found; install it: https://cloud.google.com/sdk/docs/install" >&2; exit 1; }
gc() { "$GCLOUD" --project="$PROJECT" --quiet "$@"; }

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nError: %s\n' "$*" >&2; exit 1; }

step "Checking prerequisites in $PROJECT"
# Parse rather than `source` the file, so nothing in it gets executed.
if [[ -z "${GEMINI_API_KEY:-}" && -f "$ENV_FILE" ]]; then
  GEMINI_API_KEY="$(grep -E '^GEMINI_API_KEY=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '\r' | sed -E 's/^["'"'"']|["'"'"']$//g')"
fi
[[ -n "${GEMINI_API_KEY:-}" ]] \
  || fail "no Gemini key. Set GEMINI_API_KEY, or put GEMINI_API_KEY=... in $ENV_FILE (or point ENV_FILE at a file that has it)"
# Keys are tokens like "AIza..." or "AQ.Ab8..."; anything with spaces, quotes or
# backslashes is a mangled value and would also break the YAML below.
[[ "$GEMINI_API_KEY" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || fail "GEMINI_API_KEY in $ENV_FILE doesn't look like an API key"
gc storage buckets describe "gs://$BUCKET" >/dev/null 2>&1 || fail "bucket gs://$BUCKET not found"
echo "Gemini key found (${#GEMINI_API_KEY} chars), bucket OK"

# Pass settings through a private temp file rather than --set-env-vars, so the
# key never appears on the command line or in the process list.
ENV_VARS_FILE="$(mktemp)"
trap 'rm -f "$ENV_VARS_FILE"' EXIT
chmod 600 "$ENV_VARS_FILE"
cat > "$ENV_VARS_FILE" <<YAML
GEMINI_API_KEY: "$GEMINI_API_KEY"
GEMINI_MODEL: "$GEMINI_MODEL"
GCS_BUCKET: "$BUCKET"
GCS_PUBLIC_URLS: "true"
YAML

if [[ -z "${SKIP_BUILD:-}" ]]; then
  step "Building $IMAGE"
  gc builds submit --region="$REGION" --tag="$IMAGE" .
fi

step "Deploying $SERVICE to Cloud Run ($REGION)"
gc run deploy "$SERVICE" \
  --region="$REGION" \
  --image="$IMAGE" \
  --service-account="$SERVICE_ACCOUNT" \
  --env-vars-file="$ENV_VARS_FILE" \
  --allow-unauthenticated \
  --timeout=300 \
  --min-instances="$MIN_INSTANCES" \
  --max-instances="$MAX_INSTANCES" \
  --cpu-boost \
  --memory=512Mi

URL="$(gc run services describe "$SERVICE" --region="$REGION" --format='value(status.url)')"

step "Smoke test"
curl -fsS "$URL/health" >/dev/null && echo "GET /health  ok" || fail "$URL/health did not respond"
curl -fsS "$URL/models" >/dev/null && echo "GET /models  ok" || fail "$URL/models failed (check bucket access)"

printf '\nDeployed: %s\n  viewer: %s/viewer\n  docs:   %s/docs\n' "$URL" "$URL" "$URL"
