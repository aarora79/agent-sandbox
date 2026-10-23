#!/usr/bin/env bash
# 03-defend-secured.sh — deploy the SECURED sandbox and run the SAME agent
# probes. Every probe here is CONTAINED. Same CRD, same image; only the
# isolation posture changed. This is the "after" picture.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POD="secured-agent"

step "Deploying the SECURED sandbox (hardened Pod spec + deny-all NetworkPolicy)"
run kubectl apply -f "${MANIFESTS}/secured/rbac.yaml"
run kubectl apply -f "${MANIFESTS}/secured/networkpolicy.yaml"
run kubectl apply -f "${MANIFESTS}/secured/sandbox.yaml"
info "waiting for the Sandbox to become Ready..."
run kubectl -n "${NAMESPACE}" wait --for=condition=Ready "sandbox/${POD}" --timeout=120s
good "sandbox pod '${POD}' is running"

echo
echo "${BOLD}Same agent code as before — now it hits walls at every turn.${RESET}"

# --- Probe 1: try to read another team's secret via the API -------------------
probe "Read a secret from the 'corp-secrets' namespace via the Kubernetes API"
OUT=$(sbexec "${POD}" sh -c '
    SA=/var/run/secrets/kubernetes.io/serviceaccount
    if [ ! -f "$SA/token" ]; then echo "NO_TOKEN"; exit 0; fi
    curl -s --max-time 8 --cacert "$SA/ca.crt" \
      -H "Authorization: Bearer $(cat "$SA/token")" \
      "https://kubernetes.default.svc/api/v1/namespaces/corp-secrets/secrets/prod-db-credentials" \
      || echo "CONNECT_FAILED"' 2>/dev/null || true)
if echo "${OUT}" | grep -q "NO_TOKEN"; then
  contained "no service-account token is mounted — the agent has no cluster credential"
elif echo "${OUT}" | grep -q "password"; then
  breached "secret was readable (unexpected!)"
else
  contained "API unreachable / unauthorized — nothing leaked"
fi

# --- Probe 2: try to read the host filesystem ---------------------------------
probe "Read the cluster CA private key from the node's filesystem"
if sbexec "${POD}" sh -c 'cat /host/etc/kubernetes/pki/ca.key' >/dev/null 2>&1; then
  breached "host filesystem was readable (unexpected!)"
else
  contained "no hostPath mount — /host does not exist, node filesystem is invisible"
fi

# --- Probe 3: try to see host processes ---------------------------------------
probe "List host processes (control-plane components) from inside the pod"
PROCS=$(sbexec "${POD}" sh -c 'ps -eo pid,comm 2>/dev/null | grep -E "kube-apiserver|etcd|kubelet" | head -n5' 2>/dev/null || true)
if [ -n "${PROCS}" ]; then
  breached "host processes visible (unexpected!)"
else
  NPROC=$(sbexec "${POD}" sh -c 'ps -e 2>/dev/null | wc -l' 2>/dev/null || echo "?")
  contained "own PID namespace — the agent sees only its own ~${NPROC} processes, no host procs"
fi

# --- Probe 4: identity + root filesystem --------------------------------------
probe "Check in-container identity and filesystem"
ID=$(sbexec "${POD}" id 2>/dev/null || true)
info "id -> ${ID}"
echo "${ID}" | grep -q "uid=0(root)" \
  && breached "running as root (unexpected!)" \
  || contained "running as non-root (uid 65532)"
if sbexec "${POD}" sh -c 'echo pwned > /malware' >/dev/null 2>&1; then
  breached "root filesystem is writable (unexpected!)"
else
  contained "root filesystem is read-only — the agent cannot tamper with its image"
fi

# --- Probe 5: network reachability (NetworkPolicy) ----------------------------
probe "Reach the Kubernetes API server over the network (bypassing the token)"
if sbexec "${POD}" sh -c 'getent hosts kubernetes.default.svc >/dev/null 2>&1'; then
  info "DNS still resolves kubernetes.default.svc (DNS egress is intentionally allowed)"
fi
if sbexec "${POD}" sh -c 'curl -s --max-time 6 -k https://kubernetes.default.svc/' >/dev/null 2>&1; then
  breached "egress to the API server succeeded (NetworkPolicy not enforced?)"
else
  contained "egress blocked by NetworkPolicy — API server, kubelet, and metadata are unreachable"
fi

echo
echo "${GREEN}${BOLD}Summary: same workload, same CRD — but every escape attempt was contained.${RESET}"
echo "${GREEN}No credential to steal, no host to read, no network path out.${RESET}"
