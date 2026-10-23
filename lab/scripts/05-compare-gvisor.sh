#!/usr/bin/env bash
# 05-compare-gvisor.sh — prove gVisor adds something OVER the hardened default.
#
# Runs the SAME hardened spec in two pods on the same cluster:
#   * secured-agent         -> default runc runtime (shared host kernel)
#   * secured-agent-gvisor  -> runtimeClassName: gvisor (userspace kernel)
# then runs identical kernel-surface probes on each. The runc pod is fully
# locked down (no token, no host mounts, non-root, read-only fs, deny-all egress)
# yet it is STILL executing on the node's real kernel — it can read the host
# kernel version, enumerate the node's loaded kernel modules, and make syscalls
# that are serviced by the host kernel (the exact surface kernel-escape CVEs
# abuse). Under gVisor those same actions hit runsc's reimplemented kernel
# instead, so the host kernel is neither visible nor reachable.
#
# Prereq:  WITH_GVISOR=1 ./scripts/01-up.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNC_POD="secured-agent"
GVISOR_POD="secured-agent-gvisor"

if ! kubectl get runtimeclass gvisor >/dev/null 2>&1; then
  bad "RuntimeClass 'gvisor' not found. Run: WITH_GVISOR=1 ./scripts/01-up.sh"
  exit 1
fi

step "Deploying the SAME hardened spec on runc and on gVisor"
run kubectl apply -f "${MANIFESTS}/secured/rbac.yaml"
run kubectl apply -f "${MANIFESTS}/secured/networkpolicy.yaml"
run kubectl apply -f "${MANIFESTS}/secured/sandbox.yaml"
run kubectl apply -f "${MANIFESTS}/gvisor/sandbox-gvisor.yaml"
run kubectl -n "${NAMESPACE}" wait --for=condition=Ready "sandbox/${RUNC_POD}" --timeout=120s
run kubectl -n "${NAMESPACE}" wait --for=condition=Ready "sandbox/${GVISOR_POD}" --timeout=180s
good "both sandboxes are Ready"

# io_uring_setup(entries=1, params=NULL): io_uring is a host-kernel subsystem
# behind many container-escape CVEs. On the real kernel the call reaches
# io_uring and faults reading our NULL params (EFAULT) — i.e. the subsystem is
# present and reachable. gVisor does not implement io_uring at all, so it
# returns ENOSYS: that entire attack surface simply does not exist.
read -r -d '' IOURING_PROBE <<'PY' || true
import ctypes, errno
libc = ctypes.CDLL(None, use_errno=True)
ctypes.set_errno(0)
r = libc.syscall(425, 1, 0)   # aarch64 io_uring_setup = 425, params=NULL
e = ctypes.get_errno()
if e == errno.ENOSYS:
    print("ENOSYS - no io_uring in this kernel; the subsystem is not reachable")
else:
    print(f"REACHED the host kernel's io_uring subsystem (errno={errno.errorcode.get(e, e)})")
PY

compare() {
  local title="$1"; shift
  probe "${title}"
  local runc gvisor
  runc=$(sbexec "${RUNC_POD}" "$@" 2>/dev/null || true)
  gvisor=$(sbexec "${GVISOR_POD}" "$@" 2>/dev/null || true)
  printf "    %-10s %s\n" "runc:" "${runc}"
  printf "    %-10s %s\n" "gvisor:" "${gvisor}"
}

compare "Which kernel is the agent actually running on? (uname -r)" uname -r
compare "Enumerate the node's loaded kernel modules (ls /sys/module | wc -l)" \
  sh -c 'ls /sys/module 2>/dev/null | wc -l'
compare "Invoke io_uring, a kernel-escape-prone subsystem — is it even there?" \
  python3 -c "${IOURING_PROBE}"

echo
echo "${BOLD}Reading the results:${RESET}"
echo "  ${RED}runc${RESET}  : real node kernel (e.g. 6.x), ~hundreds of host modules visible,"
echo "          io_uring reaches the HOST kernel — a live shared-kernel attack surface."
echo "  ${GREEN}gvisor${RESET}: '*-gvisor' kernel, zero host modules, io_uring is ENOSYS —"
echo "          the host kernel is neither visible nor reachable."
echo
echo "${BOLD}${GREEN}That gap is what gVisor adds over the hardened default:${RESET} the hardened"
echo "runc pod is still one host-kernel bug away from escape; gVisor removes the"
echo "shared kernel as a target. Same Sandbox CRD — only runtimeClassName changed."
