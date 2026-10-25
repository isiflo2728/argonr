#!/usr/bin/env bash
# Build the backend image and deploy it to Cloud Run.
#
#   ./deploy.sh              # build + deploy + smoke test
#   SKIP_BUILD=1 ./deploy.sh # redeploy the last built image (e.g. after changing env vars)
#
# Every setting can be overridden from the environment, e.g.
#   PROJECT=my-project BUCKET=my-bucket ./deploy.sh
#
# Prerequisites (one-time, see README "Deploy"): the Gemini secret exists and
# the service account can read it and write to the bucket. This script checks
# them but never creates or reads secrets.
set -euo pipefail

PROJECT="${PROJECT:-printbot-f7f6d}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-argonr-backend}"
BUCKET="${BUCKET:-argon-hackathon-models-383c2c}"
SECRET="${SECRET:-gemini-api-key}"
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
gc secrets describe "$SECRET" >/dev/null 2>&1 \
  || fail "secret '$SECRET' does not exist. Create it once with:
  grep '^GEMINI_API_KEY=' .env | cut -d= -f2- | tr -d '\\n' | gcloud secrets create $SECRET --project=$PROJECT --replication-policy=automatic --data-file=-"
gc secrets get-iam-policy "$SECRET" --format=json | grep -q "serviceAccount:$SERVICE_ACCOUNT" \
  || fail "$SERVICE_ACCOUNT cannot read '$SECRET'. Grant it with:
  gcloud secrets add-iam-policy-binding $SECRET --project=$PROJECT --member=serviceAccount:$SERVICE_ACCOUNT --role=roles/secretmanager.secretAccessor"
gc storage buckets describe "gs://$BUCKET" >/dev/null 2>&1 || fail "bucket gs://$BUCKET not found"
echo "secret, access and bucket OK"

if [[ -z "${SKIP_BUILD:-}" ]]; then
  step "Building $IMAGE"
  gc builds submit --region="$REGION" --tag="$IMAGE" .
fi

step "Deploying $SERVICE to Cloud Run ($REGION)"
gc run deploy "$SERVICE" \
  --region="$REGION" \
  --image="$IMAGE" \
  --service-account="$SERVICE_ACCOUNT" \
  --set-secrets="GEMINI_API_KEY=${SECRET}:latest" \
  --set-env-vars="GCS_BUCKET=${BUCKET},GCS_PUBLIC_URLS=true,GEMINI_MODEL=${GEMINI_MODEL}" \
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
