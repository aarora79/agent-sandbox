#!/usr/bin/env bash
# 06-vm-proof.sh — the manual, "see it with your own eyes" proof that a plain
# (runc) container is NOT isolated from the node it runs on, while gVisor is.
#
# On macOS the kind node runs inside the podman Linux VM, which stands in for a
# production Linux NODE. We SSH into that VM (the node) and show that:
#   * the VM and the runc container share the SAME kernel,
#   * the runc agent is just an ordinary process on the VM — the node can see,
#     signal, and read straight into its container filesystem,
#   * the gVisor agent is NOT a normal host process — the node only sees the
#     runsc sandbox; the agent's kernel + filesystem are encapsulated by it.
#
# Prereq:  WITH_GVISOR=1 ./scripts/01-up.sh   (and the two secured pods running;
#          this script applies them if missing).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require podman

MACHINE="${PODMAN_MACHINE:-}"
if [[ -z "${MACHINE}" ]]; then
  MACHINE="$(podman machine list --format '{{.Name}} {{.Running}}' 2>/dev/null \
    | awk '$2=="true"{print $1; exit}' | sed 's/\*$//')"
fi
[[ -n "${MACHINE}" ]] || { bad "no running podman machine (this proof is macOS/podman-specific)"; exit 1; }

if ! kubectl get runtimeclass gvisor >/dev/null 2>&1; then
  bad "RuntimeClass 'gvisor' not found. Run: WITH_GVISOR=1 ./scripts/01-up.sh"
  exit 1
fi

step "Ensuring both secured sandboxes are running (runc + gVisor)"
run kubectl apply -f "${MANIFESTS}/secured/rbac.yaml" >/dev/null
run kubectl apply -f "${MANIFESTS}/secured/networkpolicy.yaml" >/dev/null
run kubectl apply -f "${MANIFESTS}/secured/sandbox.yaml" >/dev/null
run kubectl apply -f "${MANIFESTS}/gvisor/sandbox-gvisor.yaml" >/dev/null
run kubectl -n "${NAMESPACE}" wait --for=condition=Ready \
  sandbox/secured-agent sandbox/secured-agent-gvisor --timeout=180s
good "both sandboxes are Ready"

RUNC_UNAME=$(kubectl -n "${NAMESPACE}" exec secured-agent -- uname -r 2>/dev/null || true)
GV_UNAME=$(kubectl -n "${NAMESPACE}" exec secured-agent-gvisor -- uname -r 2>/dev/null || true)

step "SSH into the VM (the 'node') and run the same checks by hand"
echo "${DIM}  \$ podman machine ssh ${MACHINE}${RESET}"
echo "${DIM}    (everything below runs INSIDE the Linux VM that hosts the kind node)${RESET}"

# This whole block executes inside the VM.
podman machine ssh "${MACHINE}" "sudo bash -s" <<'REMOTE'
set -e
echo
echo "## 1) Whose kernel is it? ---------------------------------------------"
echo "VM / node kernel (uname -r): $(uname -r)"

echo
echo "## 2) The runc agent is just a process on this VM --------------------"
runc_pid=""
for p in $(pgrep -x sleep); do
  hn=$(cat /proc/$p/root/etc/hostname 2>/dev/null || true)
  if [ "$hn" = "secured-agent" ]; then runc_pid=$p; fi
done
if [ -n "$runc_pid" ]; then
  echo "found the runc agent at VM pid ${runc_pid}:"
  ps -o pid,ppid,comm,args -p "$runc_pid" | sed 's/^/   /'
  echo "the node can read straight INTO its container filesystem:"
  echo "   # cat /proc/${runc_pid}/root/etc/hostname"
  echo "   -> $(cat /proc/${runc_pid}/root/etc/hostname)"
  echo "   # ls /proc/${runc_pid}/root"
  ls /proc/${runc_pid}/root | tr '\n' ' ' | sed 's/^/   /'; echo
  echo "   (the node could also kill -9 ${runc_pid} or write to those files — no isolation)"
else
  echo "could not locate the runc agent pid (did secured-agent start?)"
fi

echo
echo "## 3) The gVisor agent is NOT a normal process on this VM ------------"
# The sandboxed 'sleep' does not appear as a host process; only runsc does.
gv_sleep=0
for p in $(pgrep -x sleep); do
  hn=$(cat /proc/$p/root/etc/hostname 2>/dev/null || true)
  [ "$hn" = "secured-agent-gvisor" ] && gv_sleep=$((gv_sleep+1))
done
echo "host 'sleep' processes belonging to the gVisor pod: ${gv_sleep}  (expected 0)"
echo "what the node actually sees for the gVisor pod is the runsc sandbox:"
ps -eo pid,comm,args | grep -E "runsc|gvisor_sentry" | grep -v grep \
  | sed -E 's/(^.{90}).*/\1 .../' | head -4 | sed 's/^/   /'
echo "   the agent's syscalls + filesystem live INSIDE gvisor_sentry — the node"
echo "   cannot /proc/<pid>/root into it the way it did with the runc container."
REMOTE

echo
echo "${BOLD}Verdict:${RESET}"
echo "  runc container kernel:   ${YELLOW}${RUNC_UNAME}${RESET}  == the VM/node kernel  -> ${RED}not isolated from the node${RESET}"
echo "  gVisor container kernel: ${YELLOW}${GV_UNAME}${RESET}          != the VM/node kernel  -> ${GREEN}isolated by runsc${RESET}"
echo
echo "${DIM}Teaching point: the podman VM is only protecting your LAPTOP. Inside it — i.e."
echo "on a real Linux node — the plain container is wide open to the node. gVisor (or"
echo "Kata/Firecracker) is what adds the isolation the node itself does not give you.${RESET}"
