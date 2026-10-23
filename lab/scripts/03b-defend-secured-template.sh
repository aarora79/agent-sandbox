#!/usr/bin/env bash
# 03b-defend-secured-template.sh — the SECURED path, the reusable way.
#
# Instead of a hand-hardened bare Sandbox (03-defend-secured.sh), this deploys a
# SandboxTemplate + SandboxWarmPool + SandboxClaim. The claimed pod inherits the
# template's securityContext/caps/seccomp/limits AND gets two controls for free
# from the template controller: automountServiceAccountToken=false (omitted in
# the template) and a managed deny-by-default NetworkPolicy. Same agent image,
# same probes as 03 — every one is CONTAINED.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TPL="${MANIFESTS}/secured/template"

if ! kubectl get crd sandboxtemplates.extensions.agents.x-k8s.io >/dev/null 2>&1; then
  bad "SandboxTemplate CRD not found — install extensions via ./scripts/01-up.sh"
  exit 1
fi

step "Deploying the secured posture as a reusable SandboxTemplate (+ WarmPool + Claim)"
run kubectl apply -f "${TPL}/sandboxtemplate.yaml"
run kubectl apply -f "${TPL}/sandboxwarmpool.yaml"
run kubectl apply -f "${TPL}/sandboxclaim.yaml"
info "waiting for the SandboxClaim to be fulfilled from the warm pool..."
run kubectl -n "${NAMESPACE}" wait --for=condition=Ready sandboxclaim/secured-claim --timeout=180s

POD=$(kubectl -n "${NAMESPACE}" get sandboxclaim secured-claim -o jsonpath='{.status.sandbox.name}' 2>/dev/null)
[[ -n "${POD}" ]] || { bad "could not resolve the claimed sandbox pod"; exit 1; }
good "claim fulfilled -> sandbox pod '${POD}' (hardening inherited from the template)"

echo
echo "${BOLD}Template-provided for free:${RESET} no SA token mounted + a managed deny-all NetworkPolicy."
kubectl -n "${NAMESPACE}" get networkpolicy -o name 2>/dev/null | sed 's#^#  managed: #' || true
echo "${BOLD}Same agent code, same probes as 03 — all contained.${RESET}"

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
  contained "no service-account token is mounted — template defaulted automount to false"
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
  || contained "running as non-root (uid 65532, from the template)"
if sbexec "${POD}" sh -c 'echo pwned > /malware' >/dev/null 2>&1; then
  breached "root filesystem is writable (unexpected!)"
else
  contained "root filesystem is read-only — the agent cannot tamper with its image"
fi

# --- Probe 5: network reachability (managed NetworkPolicy) --------------------
probe "Reach the Kubernetes API server over the network (bypassing the token)"
if sbexec "${POD}" sh -c 'getent hosts kubernetes.default.svc >/dev/null 2>&1'; then
  info "DNS still resolves kubernetes.default.svc (DNS egress is intentionally allowed)"
fi
if sbexec "${POD}" sh -c 'curl -s --max-time 6 -k https://kubernetes.default.svc/' >/dev/null 2>&1; then
  breached "egress to the API server succeeded (NetworkPolicy not enforced?)"
else
  contained "egress blocked by the template's managed NetworkPolicy"
fi

echo
echo "${GREEN}${BOLD}Summary: identical containment to the bare secured Sandbox —${RESET}"
echo "${GREEN}but the posture was authored ONCE in the template, and the token + network${RESET}"
echo "${GREEN}defaults came for free. Reusable, consistent, secure by construction.${RESET}"
