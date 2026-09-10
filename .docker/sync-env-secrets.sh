#!/usr/bin/env bash
# Create a GitHub *environment* and push its secrets from a .docker/.env.<env>
# file, so deploy-application.yaml can read them via `secrets: inherit`.
#
# There is a single environment — prod, pinned to the only deployment branch,
# main — and it gets one secret per KEY=VALUE line in its env file
# (REGISTRY/TAG are skipped — CI computes those).
#
# CHATGPT_COOKIES and CHATGPT_ACCESS_TOKEN are long single-line values and the
# token expires about every 10 days, so re-running this script is the normal way
# to rotate credentials: refresh the env file, sync, re-run the deploy workflow.
#
# Requirements: gh CLI authed with repo admin (`gh auth login`), run from repo root.
#
# Usage:
#   ./.docker/sync-env-secrets.sh                          # prod from .docker/.env.prod (falls back to .docker/.env)
#   REPO=Owner/repo ./.docker/sync-env-secrets.sh
#   ENV_FILE=.docker/.env ENVIRONMENTS="prod" ./.docker/sync-env-secrets.sh
set -euo pipefail

REPO="${REPO:-bentran1vn/chatgpt-proxy-v2}"
ENVIRONMENTS="${ENVIRONMENTS:-prod}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# Keys present in the env file that should NOT become secrets (computed in CI).
EXCLUDE='^(REGISTRY|TAG)='

# Which deployment branch each environment is restricted to (empty => allow all).
branch_for_env() {
  case "$1" in
    prod) echo "main" ;;
    *)    echo "" ;;
  esac
}

command -v gh >/dev/null || { echo "gh CLI not found — install it and run 'gh auth login'." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated — run 'gh auth login'." >&2; exit 1; }

for ENV in $ENVIRONMENTS; do
  # Per-environment file: prefer .env.<env>, fall back to $ENV_FILE / .env
  FILE="${ENV_FILE:-$DIR/.env.$ENV}"
  [ -f "$FILE" ] || FILE="$DIR/.env"
  [ -f "$FILE" ] || { echo "env file not found for '$ENV' (looked for $DIR/.env.$ENV and $DIR/.env)" >&2; exit 1; }

  BRANCH="$(branch_for_env "$ENV")"

  echo ">> Ensuring environment '$ENV' exists..."
  if [ -n "$BRANCH" ]; then
    # Enable custom branch policies so we can pin the environment to one branch.
    gh api -X PUT "repos/$REPO/environments/$ENV" --input - >/dev/null <<JSON
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
    # Add the branch rule if it isn't already present (idempotent).
    existing="$(gh api "repos/$REPO/environments/$ENV/deployment-branch-policies" --jq '.branch_policies[].name' 2>/dev/null || true)"
    if ! printf '%s\n' "$existing" | grep -qx "$BRANCH"; then
      echo "   + restricting deployments to branch '$BRANCH'"
      gh api -X POST "repos/$REPO/environments/$ENV/deployment-branch-policies" -f name="$BRANCH" >/dev/null
    fi
  else
    gh api -X PUT "repos/$REPO/environments/$ENV" >/dev/null
  fi

  echo ">> Setting secrets for '$ENV' from $FILE ..."
  gh secret set \
    --repo "$REPO" \
    --env "$ENV" \
    --env-file <(grep -vE '^[[:space:]]*#' "$FILE" | grep '=' | grep -vE "$EXCLUDE")

  echo ">> Done '$ENV'. ($(gh secret list --repo "$REPO" --env "$ENV" | wc -l | tr -d ' ') secrets)"
done

echo "All set. Verify with: gh secret list --repo $REPO --env prod"

# ENVIRONMENTS="prod" ENV_FILE=.docker/.env.prod ./.docker/sync-env-secrets.sh
