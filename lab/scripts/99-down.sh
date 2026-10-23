#!/usr/bin/env bash
# 99-down.sh — delete the kind cluster and everything in it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "Deleting kind cluster '${CLUSTER_NAME}'"
run kind delete cluster --name "${CLUSTER_NAME}"
good "lab torn down"
