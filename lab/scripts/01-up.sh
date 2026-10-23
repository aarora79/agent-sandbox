#!/usr/bin/env bash
# 01-up.sh — stand up the lab cluster from scratch.
#
#   1. create a kind cluster (Calico CNI so NetworkPolicy is actually enforced)
#   2. pre-load the demo container image into the cluster
#   3. install the agent-sandbox controller (the Sandbox CRD)
#   4. create the demo namespaces and the "loot" secret
#
# Idempotent-ish: it deletes any existing cluster of the same name first.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kind
require kubectl
require docker # on this box `docker` is podman; either works for `kind load`

# WITH_GVISOR=1 adds kernel-level isolation: install runsc into the VM, create
# the cluster with the gVisor-aware containerd config, and register a RuntimeClass.
KIND_CONFIG="${LAB_DIR}/kind-config.yaml"
if [[ "${WITH_GVISOR:-0}" == "1" ]]; then
  KIND_CONFIG="${MANIFESTS}/gvisor/kind-config.yaml"
  "${SCRIPT_DIR}/install-runsc.sh"
fi

step "Recreating kind cluster '${CLUSTER_NAME}' (podman provider, Calico CNI)"
run kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
run kind create cluster --config "${KIND_CONFIG}" --wait 120s

step "Installing Calico CNI (enforces NetworkPolicy)"
run kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
info "waiting for Calico to program the dataplane..."
run kubectl rollout status daemonset/calico-node -n kube-system --timeout=300s
run kubectl wait --for=condition=Ready node --all --timeout=180s
good "cluster networking ready"

step "Pre-loading demo image '${NETSHOOT_IMAGE}' into the cluster"
run docker pull "${NETSHOOT_IMAGE}"
run kind load docker-image "${NETSHOOT_IMAGE}" --name "${CLUSTER_NAME}"
good "image available on the node (no in-pod pull needed)"

step "Installing agent-sandbox controller ${AGENT_SANDBOX_VERSION}"
run kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/sandbox-with-extensions.yaml"
info "waiting for the Sandbox CRD to register..."
run kubectl wait --for=condition=Established crd/sandboxes.agents.x-k8s.io --timeout=120s
info "waiting for the controller to come up..."
run kubectl rollout status deployment/agent-sandbox-controller -n agent-sandbox-system --timeout=180s
good "Sandbox CRD and controller are ready"

step "Creating demo namespaces and the sensitive secret"
run kubectl apply -f "${MANIFESTS}/00-setup.yaml"
good "lab environment is ready"

if [[ "${WITH_GVISOR:-0}" == "1" ]]; then
  step "Registering the gVisor RuntimeClass"
  run kubectl apply -f "${MANIFESTS}/gvisor/runtimeclass.yaml"
  good "RuntimeClass 'gvisor' is available — set runtimeClassName: gvisor on a Sandbox"
fi

cat <<EOF

${BOLD}${GREEN}Lab is up.${RESET}
Next:
  ${BOLD}./scripts/02-attack-unsecured.sh${RESET}   # watch an unsecured agent own the node + cluster
  ${BOLD}./scripts/03-defend-secured.sh${RESET}     # watch the same attacks bounce off a hardened sandbox
Or run both back-to-back:
  ${BOLD}./scripts/demo.sh${RESET}
Tear down with:
  ${BOLD}./scripts/99-down.sh${RESET}
EOF
