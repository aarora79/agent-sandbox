#!/usr/bin/env bash
# preflight-kvm.sh — can THIS machine run the VM-based sandbox runtimes
# (Kata Containers, Firecracker)? Both require hardware virtualization exposed
# as /dev/kvm. gVisor does NOT (see install-runsc.sh / 04-harden-gvisor.sh).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "KVM preflight — checking for hardware virtualization (/dev/kvm)"

os="$(uname -s)"
info "host OS: ${os} ($(uname -m))"

check_vm_kvm() {
  # Check inside the podman VM, since that's where kind nodes actually run on macOS.
  local machine
  machine="$(podman machine list --format '{{.Name}} {{.Running}}' 2>/dev/null \
    | awk '$2=="true"{print $1; exit}' | sed 's/\*$//')"
  [[ -n "${machine}" ]] || { warn "no running podman machine"; return 1; }
  info "inspecting podman VM '${machine}'..."
  podman machine ssh "${machine}" 'ls -l /dev/kvm 2>/dev/null && echo KVM_PRESENT || echo KVM_ABSENT' 2>/dev/null
}

verdict_ok=0
if [[ "${os}" == "Darwin" ]]; then
  info "chip: $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  info "macOS: $(sw_vers -productVersion 2>/dev/null)"
  echo
  warn "On macOS, containers run inside the podman/Docker Linux VM. Kata/Firecracker"
  warn "would need KVM INSIDE that VM, i.e. NESTED virtualization — only available on"
  warn "Apple M3+ with macOS 15+ (and a hypervisor that exposes it). M1/M2 cannot."
  echo
  if check_vm_kvm | grep -q KVM_PRESENT; then
    good "/dev/kvm IS present in the VM — you may be able to run Kata/Firecracker"
    verdict_ok=1
  else
    bad "/dev/kvm is NOT present in the VM — Kata and Firecracker cannot run here"
  fi
elif [[ "${os}" == "Linux" ]]; then
  if [[ -e /dev/kvm ]]; then
    good "/dev/kvm present — this Linux host can run Kata/Firecracker"
    verdict_ok=1
  else
    bad "/dev/kvm missing — enable virtualization (VT-x/AMD-V) or use a bare-metal/nested-virt host"
  fi
fi

echo
if [[ "${verdict_ok}" == "1" ]]; then
  echo "${GREEN}${BOLD}VERDICT: KVM available.${RESET} See manifests/kata/ and manifests/firecracker/."
else
  echo "${YELLOW}${BOLD}VERDICT: no KVM here.${RESET} Use gVisor on this machine"
  echo "  (WITH_GVISOR=1 ./scripts/01-up.sh), and run the Kata/Firecracker steps on a"
  echo "  bare-metal Linux host or a cloud node pool (GKE Sandbox, AKS, bare-metal, etc.)."
fi
