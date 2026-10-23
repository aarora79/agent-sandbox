#!/usr/bin/env bash
# Shared helpers for the sandboxing lab scripts.
set -euo pipefail

CLUSTER_NAME="agent-sandbox-demo"
NAMESPACE="agent-sandbox-demo"
SECRET_NS="corp-secrets"
AGENT_SANDBOX_VERSION="v1.0.6"
NETSHOOT_IMAGE="nicolaka/netshoot:v0.13"
CALICO_VERSION="v3.28.2"

# kind on this workstation uses the podman provider.
export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFESTS="${LAB_DIR}/manifests"

# --- pretty output -----------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; RESET=""
fi

step()  { echo; echo "${BOLD}${BLUE}==>${RESET} ${BOLD}$*${RESET}"; }
info()  { echo "${CYAN}  - $*${RESET}"; }
good()  { echo "${GREEN}  ✓ $*${RESET}"; }
bad()   { echo "${RED}  ✗ $*${RESET}"; }
warn()  { echo "${YELLOW}  ! $*${RESET}"; }

# Echo a command (dimmed) and then run it.
run() { echo "${DIM}  \$ $*${RESET}"; "$@"; }

# Run a command inside a sandbox pod via kubectl exec.
sbexec() {
  local pod="$1"; shift
  kubectl -n "${NAMESPACE}" exec "${pod}" -- "$@"
}

# Pretty header for an attack probe. Usage: probe "description"
probe() { echo; echo "${BOLD}${YELLOW}▶ PROBE:${RESET} ${BOLD}$*${RESET}"; }

# Mark an outcome. breached => the agent got access it should not have.
breached() { echo "${RED}${BOLD}  ⚠ BREACH:${RESET} ${RED}$*${RESET}"; }
contained() { echo "${GREEN}${BOLD}  🛡 CONTAINED:${RESET} ${GREEN}$*${RESET}"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { bad "missing required tool: $1"; exit 1; }
}
