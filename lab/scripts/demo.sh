#!/usr/bin/env bash
# demo.sh — run the whole story back to back: unsecured breach, then secured
# containment (bare Sandbox), then the same containment via a reusable
# SandboxTemplate. Assumes ./01-up.sh has already been run.
set -euo pipefail
HERE="$(dirname "${BASH_SOURCE[0]}")"
source "${HERE}/lib.sh"

if ! kubectl get crd sandboxes.agents.x-k8s.io >/dev/null 2>&1; then
  bad "Sandbox CRD not found. Run ./scripts/01-up.sh first."
  exit 1
fi

"${HERE}/02-attack-unsecured.sh"
echo
read -r -p "${BOLD}Press Enter to run the SAME attacks against the secured Sandbox...${RESET} " _ || true
"${HERE}/03-defend-secured.sh"
echo
read -r -p "${BOLD}Press Enter to see the secured posture as a reusable SandboxTemplate...${RESET} " _ || true
"${HERE}/03b-defend-secured-template.sh"
