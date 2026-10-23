#!/usr/bin/env bash
# install-runsc.sh — install gVisor (runsc + shim + sidecar binaries) INTO the
# podman machine VM, so a kind node running inside that VM can use the "runsc"
# runtime. gVisor's systrap platform needs no KVM, so this works on Apple
# silicon (unlike Kata / Firecracker, which require /dev/kvm).
#
# On a Linux workstation you don't need this — install gVisor on the host per
# https://gvisor.dev/docs/user_guide/install/ and the kind node mounts it.
#
# Env:
#   PODMAN_MACHINE   name of the podman machine (default: the running one)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require podman

MACHINE="${PODMAN_MACHINE:-}"
if [[ -z "${MACHINE}" ]]; then
  MACHINE="$(podman machine list --format '{{.Name}} {{.Running}}' 2>/dev/null \
    | awk '$2=="true"{print $1; exit}' | sed 's/\*$//')"
fi
[[ -n "${MACHINE}" ]] || { bad "no running podman machine found"; exit 1; }

step "Installing gVisor runsc into podman machine '${MACHINE}'"

# shellcheck disable=SC2016
REMOTE='
set -e
if command -v runsc >/dev/null 2>&1 && [ -x /usr/local/bin/gvisor-bin/gvisor_sentry ]; then
  echo "already installed: $(runsc --version | head -1)"; exit 0
fi
A=$(uname -m)   # aarch64 or x86_64 — matches the gVisor release layout
cd /tmp
echo "downloading gVisor release for ${A}..."
curl -fsSL -o gvisor.tar.bz2 "https://storage.googleapis.com/gvisor/releases/release/latest/${A}/gvisor.tar.bz2"
tar xjf gvisor.tar.bz2
sudo install -m0755 runsc /usr/local/bin/runsc
sudo install -m0755 containerd-shim-runsc-v1 /usr/local/bin/containerd-shim-runsc-v1
sudo rm -rf /usr/local/bin/gvisor-bin
sudo cp -r gvisor-bin /usr/local/bin/gvisor-bin
sudo chmod -R 0755 /usr/local/bin/gvisor-bin
rm -f gvisor.tar.bz2
echo "installed: $(runsc --version | head -1)"
'

run podman machine ssh "${MACHINE}" "${REMOTE}"
good "runsc is available inside the VM at /usr/local/bin/runsc"
