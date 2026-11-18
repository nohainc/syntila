#!/usr/bin/env bash
# Builds the backend and deploys it to the production VPS as a new release.
# Database migrations run as part of this deploy (see below); use
# scripts/prod-migrate-db.sh only to inspect or to migrate ahead of a release.
#
#   scripts/prod-deploy-backend.sh [--yes] [--skip-tests]
#
# What happens: tests, build, upload, then on the VPS (infra/vps/deploy-backend.sh):
# a verified pre-migration dump when migrations are pending, a new release
# directory, restart (the service applies pending migrations before it starts),
# a readiness check with automatic rollback to the previous release, and a
# schema.lock drift check.
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
parse_flags "$@"
require bun; require rsync; require ssh

say "Production backend deploy: $(git_state)"
run_tests
build_backend
pending=$(pending_migrations || true)
confirm "Deploy the backend to $PROD_VPS.
Pending migrations: ${pending:-none (or could not be read)}"
stage_backend
say "Deploy on the VPS (asks for the sudo password)"
ssh -t "$PROD_VPS" "sudo bash ~/$PROD_STAGE/vps/deploy-backend.sh"
say "Public check"
curl -fsS --max-time 15 "$PROD_API_URL/health/ready" && echo && echo "ok   backend ready"
