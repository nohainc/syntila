#!/usr/bin/env bash
# Applies repository protection for the public nohainc/syntila repository.
#
# The repository stays public. Outside contributors can open pull requests, but
# nothing from a fork runs in CI without approval, no fork ever receives secrets,
# only reviewed code reaches main, and macOS releases need an approval from the
# environment reviewer. Cloud deploys run on manual dispatch from main after CI passes.
#
# Dry run by default. Pass --apply to change GitHub. Safe to re-run.
#
# Requirements: gh authenticated as a repository admin.
# Optional env: REPO (default nohainc/syntila), REVIEWER (GitHub login that
# approves deployments, default: the authenticated user), REQUIRED_APPROVALS
# (default 1; set 0 if you are the only maintainer).
set -euo pipefail

apply=false
[[ "${1:-}" == "--apply" ]] && apply=true

repo="${REPO:-nohainc/syntila}"
required_approvals="${REQUIRED_APPROVALS:-1}"
reviewer="${REVIEWER:-$(gh api user --jq .login)}"
reviewer_id="$(gh api "users/${reviewer}" --jq .id)"

# api METHOD PATH [JSON_BODY]: prints the call in dry-run, performs it with --apply.
api() {
  local method="$1" path="$2" body="${3:-}"
  if ! $apply; then
    echo "dry-run  ${method} ${path} ${body:+$body}"
    return 0
  fi
  if [[ -n "$body" ]]; then
    printf '%s' "$body" | gh api -X "$method" "$path" --input - > /dev/null
  else
    gh api -X "$method" "$path" > /dev/null
  fi
  echo "applied  ${method} ${path}"
}

visibility="$(gh api "repos/${repo}" --jq .visibility)"
echo "Repository ${repo} is ${visibility}."
if [[ "$visibility" != "public" ]]; then
  echo "warning: this script is written for a public repository." >&2
fi
echo "Deployment reviewer: ${reviewer} (id ${reviewer_id})"
echo

echo "== Repository"
api PATCH "repos/${repo}" '{"has_wiki":false,"has_projects":false,"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":true,"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'
api PUT "repos/${repo}/vulnerability-alerts"
api PUT "repos/${repo}/automated-security-fixes"

echo "== Actions: only reviewed actions, least-privilege token"
api PUT "repos/${repo}/actions/permissions" '{"enabled":true,"allowed_actions":"selected"}'
api PUT "repos/${repo}/actions/permissions/selected-actions" '{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":["pnpm/action-setup@*","subosito/flutter-action@*"]}'
api PUT "repos/${repo}/actions/permissions/workflow" '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
api PUT "repos/${repo}/actions/permissions/fork-pr-contributor-approval" '{"approval_policy":"all_external_contributors"}'

echo "== Branch ruleset for main"
ruleset="{
  \"name\": \"Protect main\",
  \"target\": \"branch\",
  \"enforcement\": \"active\",
  \"conditions\": {\"ref_name\": {\"include\": [\"refs/heads/main\"], \"exclude\": []}},
  \"rules\": [
    {\"type\": \"deletion\"},
    {\"type\": \"non_fast_forward\"},
    {\"type\": \"required_linear_history\"},
    {\"type\": \"pull_request\", \"parameters\": {
      \"required_approving_review_count\": ${required_approvals},
      \"dismiss_stale_reviews_on_push\": true,
      \"require_code_owner_review\": true,
      \"require_last_push_approval\": true,
      \"required_review_thread_resolution\": true,
      \"allowed_merge_methods\": [\"squash\"]
    }},
    {\"type\": \"required_status_checks\", \"parameters\": {
      \"strict_required_status_checks_policy\": true,
      \"required_status_checks\": [{\"context\": \"CI passed\"}]
    }}
  ]
}"
existing_id="$(gh api "repos/${repo}/rulesets" --jq '.[] | select(.name == "Protect main") | .id' | head -n 1)"
if [[ -n "$existing_id" ]]; then
  api PUT "repos/${repo}/rulesets/${existing_id}" "$ruleset"
else
  api POST "repos/${repo}/rulesets" "$ruleset"
fi

echo "== Environments"
# production: cloud deploys. No reviewer. Manual dispatch from main, gated by a passing CI run.
# production-site: public site deploys on push to main. No reviewer, main only.
# workspace-release: macOS Workspace releases. Reviewer approval, main only.
set_environment() {
  local name="$1" with_reviewer="$2" body
  if [[ "$with_reviewer" == "true" ]]; then
    body="{\"reviewers\":[{\"type\":\"User\",\"id\":${reviewer_id}}],\"deployment_branch_policy\":{\"protected_branches\":false,\"custom_branch_policies\":true}}"
  else
    body='{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
  fi
  api PUT "repos/${repo}/environments/${name}" "$body"

  local has_main_policy
  has_main_policy="$(gh api "repos/${repo}/environments/${name}/deployment-branch-policies" \
    --jq '[.branch_policies[]? | select(.name == "main")] | length' 2>/dev/null || echo 0)"
  if [[ "$has_main_policy" == "0" ]]; then
    api POST "repos/${repo}/environments/${name}/deployment-branch-policies" '{"name":"main","type":"branch"}'
  else
    echo "exists   branch policy main for ${name}"
  fi
}
set_environment production false
set_environment production-site false
set_environment workspace-release true

echo
if $apply; then
  echo "Done. Check Settings in GitHub, then confirm a test PR shows the 'CI passed' check."
else
  echo "Dry run only. Re-run with --apply to change GitHub."
fi
echo "Manual steps the API cannot do:"
echo "  - Forking of public repositories cannot be disabled. Forks never receive secrets and need approval to run CI."
echo "  - Organization base permission should be Read (org settings > Member privileges)."
echo "  - If you are the only maintainer, add yourself as a bypass actor on the 'Protect main' ruleset in the UI,"
echo "    because GitHub does not let a pull request author approve their own change."
