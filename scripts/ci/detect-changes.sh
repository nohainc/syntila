#!/usr/bin/env bash
# Decides which CI domains must run for a pull request or push.
#
# Writes one boolean per domain to $GITHUB_OUTPUT. Any change to shared
# tooling (CI, scripts, root configs, package manifests) runs every domain,
# so a change to the test runner can never skip the tests it controls.
# workflow_dispatch, first pushes and unknown bases run everything.
set -euo pipefail

domains=(cloud dart app workspace workspace_gui profile_lab engine site)

set_output() {
  echo "$1=$2" >> "$GITHUB_OUTPUT"
}

run_everything() {
  for domain in "${domains[@]}"; do
    set_output "$domain" true
  done
}

if [[ "${EVENT_NAME:-}" == "workflow_dispatch" || -z "${BASE_SHA:-}" || "${BASE_SHA}" =~ ^0+$ ]]; then
  run_everything
  exit 0
fi

changed="$(git diff --name-only "${BASE_SHA}...${HEAD_SHA}")"
echo "Changed files:"
echo "${changed:-<none>}"

matches() {
  grep -Eq "$1" <<< "$changed"
}

shared='^(\.github/|scripts/|package\.json$|pnpm-lock\.yaml$|pnpm-workspace\.yaml$|tsconfig\.base\.json$|vitest\.config\.ts$|eslint\.config\.mjs$)'
flutter_shared='^packages/(syntila_design|dart/protocol|protocol|syntila_worker_protocol|tool_profile_v1|syntila_cli_worker_runtime)/'

if matches "$shared"; then
  run_everything
  exit 0
fi

set_output cloud "$(matches '^(apps/cloud/|packages/(core|protocol|security|workspace-runtime-protocol|tool-profile)/)' && echo true || echo false)"
set_output dart "$(matches '^packages/(syntila_cli_worker_runtime|syntila_design|syntila_worker_protocol|dart/protocol|tool_profile_v1)/' && echo true || echo false)"
set_output app "$(matches "^apps/app/|${flutter_shared}" && echo true || echo false)"
set_output workspace "$(matches "^(apps/workspace/|apps/app/|apps/profile_lab/|engines/cli_worker/)|${flutter_shared}" && echo true || echo false)"
set_output workspace_gui "$(matches "^(apps/workspace_gui/|apps/workspace/)|${flutter_shared}" && echo true || echo false)"
set_output profile_lab "$(matches "^(apps/profile_lab/|engines/cli_worker/)|${flutter_shared}" && echo true || echo false)"
set_output engine "$(matches '^(engines/cli_worker/|packages/(syntila_worker_protocol|tool_profile_v1|syntila_cli_worker_runtime)/)' && echo true || echo false)"
set_output site "$(matches '^(apps/site/|pnpm-lock\.yaml$|package\.json$)' && echo true || echo false)"
