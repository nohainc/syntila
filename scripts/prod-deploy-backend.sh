#!/usr/bin/env bash
# Builds the backend and deploys it to the production VPS as a new release.
# Database migrations run as part of this deploy (see below); use
# scripts/prod-migrate-db.sh only to inspect or to migrate ahead of a release.
#
#   scripts/prod-deploy-backend.sh [--yes] [--skip-tests] [--dry-run] [--allow-dirty]
#   --dry-run runs tests and build, then prints the upload and deploy steps.
#
# What happens: tests, build, upload, then on the VPS (infra/vps/deploy-backend.sh):
# a new release directory, restart (the service applies pending migrations before it starts),
# a readiness check with automatic rollback to the previous release, and a
# schema.lock drift check.
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
parse_flags "$@"
require bun; require rsync; require ssh

say "Production backend deploy: $(git_state)"
require_clean_main
run_tests
build_backend
pending=$(pending_migrations || true)
confirm "Deploy the backend to $PROD_VPS.
Pending migrations: ${pending:-none (or could not be read)}"
stage_backend
say "Deploy on the VPS (asks for the sudo password)"
run ssh -t "$PROD_VPS" "sudo bash ~/$PROD_STAGE/vps/deploy-backend.sh"
say "Public check"
if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] would check $PROD_API_URL/health/ready"
else curl -fsS --max-time 15 "$PROD_API_URL/health/ready" && echo && echo "ok   backend ready"; fi
