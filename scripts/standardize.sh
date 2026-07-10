#!/usr/bin/env bash
# standardize.sh — apply the uniform delivery guardrails to every macp-* repo.
#
# Idempotent. For each repo it: enables "Allow auto-merge", turns on squash +
# delete-branch-on-merge, and sets branch protection on the default branch with
# that repo's real PR check-runs as REQUIRED status checks (so auto-merge has
# something to wait on). Required-check names are per-repo — they MUST match
# each repo's actual check-run names exactly, or a required check hangs every
# PR. Each name below was verified against `gh api repos/<org>/<repo>/commits/
# main/check-runs` and the workflow `on:` triggers (push-only, tag-only,
# scheduled, dispatch-only, and advisory jobs are excluded).
#
# Portable to macOS's stock bash 3.2 (no associative arrays).
#
# Excluded on purpose:
#   website — private repo on a Free org; branch protection needs Pro/public
#             (GitHub returns 403). It still gets auto-merge + Dependabot.
#
# Prereqs: gh auth with admin:org. Org secrets (App id/key) are set separately.
# Usage: ./standardize.sh [repo ...]   (default: all repos below)
set -euo pipefail

ORG=multiagentcoordinationprotocol
ALL_REPOS="macp-runtime macp-control-plane macp-sdk-python macp-sdk-typescript macp-playground macp-ui-console macp-auth-service multiagentcoordinationprotocol"

# Emits one required check-name per line for the given repo (non-zero if unknown).
checks_for() {
  case "$1" in
    macp-runtime)
      printf '%s\n' \
        "Check (MSRV)" "Format" "Clippy" "Rustdoc" "Test" "Build" \
        "Coverage" "Crate Dependency Isolation" \
        "Conformance oracle (spec-repo fixtures)" \
        "Feature-gated code (rocksdb, redis, otel)" \
        "Integration (tier 1 + 2, real gRPC boundary)" \
        "Docker Image Build (gate)" ;;
    macp-control-plane)
      printf '%s\n' "lint" "typecheck" "test" "build" "conventions" "audit" ;;
    macp-sdk-python)
      # NB: verify-fixtures is intentionally NOT required — it tracks spec HEAD
      # and is currently red org-wide from unsynced negative-outcome fixtures
      # (run `make sync-fixtures`). Add it back once the SDKs are re-synced.
      printf '%s\n' \
        "checks / lint" "checks / typecheck" \
        "checks / test (3.11)" "checks / test (3.12)" "checks / test (3.13)" \
        "checks / conformance" ;;
    macp-sdk-typescript)
      # verify-fixtures omitted for the same spec-drift reason as macp-sdk-python.
      printf '%s\n' "build-and-test (20)" "build-and-test (22)" "build-and-test (24)" ;;
    macp-playground)
      printf '%s\n' "lint" "build" "test" "python" "docker" ;;
    macp-ui-console)
      printf '%s\n' "Lint, Type-check, Test, Build" ;;
    macp-auth-service)
      printf '%s\n' "lint" "typecheck" "test (20)" "test (22)" "build" "dependency-review" "Build Docker image" ;;
    multiagentcoordinationprotocol)  # the proto / spec repo
      printf '%s\n' "All Validations Passed" ;;
    *) return 1 ;;
  esac
}

if [ "$#" -gt 0 ]; then repos="$*"; else repos="$ALL_REPOS"; fi

for repo in $repos; do
  if ! lines=$(checks_for "$repo"); then
    echo "!! $repo: not in the standard set (excluded/unknown) — skipping"; continue
  fi
  contexts_json=$(printf '%s' "$lines" | jq -R . | jq -sc .)
  branch=$(gh api "repos/$ORG/$repo" --jq .default_branch)
  echo "== $repo (@$branch) =="

  gh api -X PATCH "repos/$ORG/$repo" \
    -F allow_auto_merge=true -F allow_squash_merge=true -F delete_branch_on_merge=true \
    --jq '"  auto-merge=\(.allow_auto_merge) squash=\(.allow_squash_merge) delete-branch=\(.delete_branch_on_merge)"'

  jq -nc --argjson ctx "$contexts_json" '{
    required_status_checks: { strict: true, contexts: $ctx },
    enforce_admins: false,
    required_pull_request_reviews: null,
    restrictions: null
  }' | gh api -X PUT "repos/$ORG/$repo/branches/$branch/protection" --input - \
      --jq '"  required checks: \(.required_status_checks.contexts | join(", "))"'
done
echo "done."
