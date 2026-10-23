#!/usr/bin/env bash
# validate-kind.sh — stand up Kata on a single-node kind cluster and prove a
# Sandbox boots a real microVM. Run on a KVM-capable Linux host (bare-metal, or
# a nested-virt VM such as an EC2 m7i launched with
# `--cpu-options NestedVirtualization=enabled`). NOT for macOS (no /dev/kvm).
#
# kind keeps kube-proxy/CNI inside the node container's netns, so this does not
# touch the host firewall/routing/SSH. Validated on EC2 m7i.2xlarge (AL2023).
#
# Result tier that WORKS under nested virt: Cloud Hypervisor (kata-clh).
#   kata-qemu crashes nested ("kvm run failed Bad address", nvdimm/-cpu host);
#   kata-fc needs a devmapper snapshotter kind doesn't provide.
# On bare metal (no nesting) kata-qemu works too — override with RUNTIME_CLASS.
set -euo pipefail
RUNTIME_CLASS="${RUNTIME_CLASS:-kata-clh}"
KATA_VERSION="${KATA_VERSION:-4.2.0}"
AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-v1.0.6}"
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

[ -e /dev/kvm ] || { echo "FATAL: /dev/kvm not present — need a KVM/nested-virt Linux host"; exit 1; }

echo "== tools =="
command -v docker >/dev/null || { $SUDO dnf install -y -q docker && $SUDO systemctl enable --now docker; }
command -v kind >/dev/null || {
  KV=$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | grep -m1 tag_name | cut -d'"' -f4)
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KV}/kind-linux-amd64" && $SUDO install /tmp/kind /usr/local/bin/kind
}
command -v kubectl >/dev/null || { curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && $SUDO install /tmp/kubectl /usr/local/bin/kubectl; }
command -v helm >/dev/null || (curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | $SUDO bash)
command -v git >/dev/null || $SUDO dnf install -y -q git

echo "== kind cluster with KVM/vhost devices mounted into the node =="
$SUDO modprobe vhost_vsock vhost_net 2>/dev/null || true
MOUNTS=""
for d in /dev/kvm /dev/vhost-vsock /dev/vhost-net; do
  [ -e "$d" ] && MOUNTS="${MOUNTS}  - hostPath: $d\n    containerPath: $d\n"
done
printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nname: kata\nnodes:\n- role: control-plane\n  extraMounts:\n%b' "$MOUNTS" | $SUDO tee /tmp/kind-kata.yaml >/dev/null
$SUDO kind delete cluster --name kata 2>/dev/null || true
$SUDO kind create cluster --name kata --config /tmp/kind-kata.yaml --wait 150s
KCTL="$SUDO env KUBECONFIG=/root/.kube/config kubectl"
$SUDO env KUBECONFIG=/root/.kube/config kind export kubeconfig --name kata

echo "== kata-deploy (Helm, Kata ${KATA_VERSION}) =="
SRC=/tmp/kata-src
[ -d "$SRC/.git" ] || { $SUDO git clone --depth 1 --branch "$KATA_VERSION" --filter=blob:none --sparse https://github.com/kata-containers/kata-containers "$SRC"; $SUDO git -C "$SRC" sparse-checkout set tools/packaging/kata-deploy/helm-chart; }
$SUDO env KUBECONFIG=/root/.kube/config helm upgrade --install kata-deploy \
  "$SRC/tools/packaging/kata-deploy/helm-chart/kata-deploy" -n kube-system --set env.createRuntimeClasses=true
echo "   waiting for node kata-runtime label..."
for i in $(seq 1 120); do $KCTL get node -o jsonpath='{.items[*].metadata.labels}' 2>/dev/null | grep -q kata-runtime && break; sleep 5; done

echo "== agent-sandbox controller =="
$KCTL apply --server-side -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/sandbox-with-extensions.yaml"
$KCTL wait --for=condition=Established crd/sandboxes.agents.x-k8s.io --timeout=180s
$KCTL -n agent-sandbox-system rollout status deploy/agent-sandbox-controller --timeout=300s

echo "== Sandbox under ${RUNTIME_CLASS} =="
$KCTL create ns val 2>/dev/null || true
printf 'apiVersion: agents.x-k8s.io/v1beta1\nkind: Sandbox\nmetadata:\n  name: kata-probe\n  namespace: val\nspec:\n  podTemplate:\n    spec:\n      runtimeClassName: %s\n      containers:\n      - name: agent\n        image: nicolaka/netshoot:v0.13\n        command: ["sleep","infinity"]\n' "$RUNTIME_CLASS" | $KCTL apply -f -
$KCTL -n val wait --for=condition=Ready sandbox/kata-probe --timeout=300s; rc=$?

echo
echo "================= RESULT ================="
echo "runtimeClassName : $($KCTL -n val get pod kata-probe -o jsonpath='{.spec.runtimeClassName}' 2>&1)"
echo "phase            : $($KCTL -n val get pod kata-probe -o jsonpath='{.status.phase}' 2>&1)"
echo "HOST  kernel     : $(uname -r)"
echo "GUEST kernel     : $($KCTL -n val exec kata-probe -- uname -r 2>&1)   <- differs => real microVM"
$KCTL -n val exec kata-probe -- sh -c 'dmesg 2>/dev/null | grep -iE "hypervisor|cloud" | head -2' 2>/dev/null | sed 's/^/guest dmesg    : /'
[ "$rc" = 0 ] || { echo "NOT READY — events:"; $KCTL -n val describe pod kata-probe 2>&1 | sed -n '/Events:/,$p' | tail -8; }
echo "=========================================="
echo "Teardown: ${SUDO} kind delete cluster --name kata"
