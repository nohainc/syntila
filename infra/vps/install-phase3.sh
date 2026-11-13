#!/usr/bin/env bash
# Superseded by deploy-backend.sh (bundled backend).
exec bash "$(dirname "$0")/deploy-backend.sh" "$@"
