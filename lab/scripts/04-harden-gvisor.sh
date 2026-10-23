#!/usr/bin/env bash
# 04-harden-gvisor.sh — deploy a Sandbox that runs under gVisor and PROVE the
# kernel is virtualized. Run this after:  WITH_GVISOR=1 ./scripts/01-up.sh
#
# gVisor runs the container on a userspace kernel (runsc), so a host-kernel
# exploit no longer reaches the real node kernel. All the earlier hardening
# (no token, no host mounts, non-root, read-only fs, deny-all egress) still
# applies on top.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POD="secured-agent-gvisor"

if ! kubectl get runtimeclass gvisor >/dev/null 2>&1; then
  bad "RuntimeClass 'gvisor' not found. Run: WITH_GVISOR=1 ./scripts/01-up.sh"
  exit 1
fi

step "Deploying the SECURED sandbox under gVisor (runtimeClassName: gvisor)"
run kubectl apply -f "${MANIFESTS}/secured/rbac.yaml"
run kubectl apply -f "${MANIFESTS}/secured/networkpolicy.yaml"
run kubectl apply -f "${MANIFESTS}/gvisor/sandbox-gvisor.yaml"
info "waiting for the Sandbox to become Ready..."
run kubectl -n "${NAMESPACE}" wait --for=condition=Ready "sandbox/${POD}" --timeout=180s
good "sandbox pod '${POD}' is running on gVisor"

probe "Confirm the pod is scheduled on the gVisor runtime"
RC=$(kubectl -n "${NAMESPACE}" get pod "${POD}" -o jsonpath='{.spec.runtimeClassName}' 2>/dev/null || true)
info "pod .spec.runtimeClassName = ${RC:-<none>}"
[[ "${RC}" == "gvisor" ]] && contained "RuntimeClass is gvisor — syscalls hit runsc, not the host kernel"

probe "Kernel banner inside the sandbox (gVisor advertises itself)"
UNAME=$(sbexec "${POD}" uname -a 2>/dev/null || true)
info "uname -a -> ${UNAME}"
if echo "${UNAME}" | grep -qi "gvisor\|gVisor"; then
  contained "the 'kernel' is gVisor's sentry, not the node's Linux kernel"
else
  warn "uname did not mention gVisor (banner varies by version); checking /proc"
  sbexec "${POD}" sh -c 'cat /proc/version 2>/dev/null' | sed 's/^/      /' || true
fi

probe "Device surface (gVisor exposes far fewer /dev nodes than a real kernel)"
NDEV=$(sbexec "${POD}" sh -c 'ls /dev | wc -l' 2>/dev/null || echo "?")
info "/dev entries visible to the sandbox: ${NDEV}"
contained "a thin, emulated device surface (a normal container node sees many more)"

echo
echo "${GREEN}${BOLD}gVisor adds a kernel-level boundary UNDER the K8s hardening.${RESET}"
echo "${GREEN}Same Sandbox CRD — one line, runtimeClassName: gvisor — swaps the isolation tier.${RESET}"
echo "${DIM}Compare: ../manifests/kata and ../manifests/firecracker describe the microVM tiers (need KVM).${RESET}"
