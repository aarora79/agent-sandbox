# Lab: Sandboxing an AI Agent on Kubernetes

A hands-on companion to the *Sandboxing Agentic AI* lecture. You stand up a
local Kubernetes cluster, install the **`agent-sandbox`** `Sandbox` CRD
(`agents.x-k8s.io/v1beta1`), then run the **same agent container image** two ways:
an **unsecured** box (a *plain Kubernetes Pod* on its defaults) vs a **secured**
`Sandbox` that is deliberately hardened:

| | Unsecured (plain Pod, defaults) | Secured (hardened Sandbox) |
|---|---|---|
| ServiceAccount token | auto-mounted (default), bound to `cluster-admin` | not mounted, zero RBAC |
| Host filesystem | `hostPath` mount of `/` (added for parity) | none |
| Host PID namespace | shared (`hostPID: true`) | own |
| Container user | root (uid 0) — **the default** | non-root (uid 65532), caps dropped |
| Root filesystem | writable (default) | read-only |
| Network | open (default) | deny-all egress (DNS only) |

The point: **security is opt-IN.** A plain Pod, straight off the Kubernetes
defaults, leaks production secrets, the cluster CA private key, and full node
access — we barely had to *do* anything. The secured box contains every one of
those attacks. (The `Sandbox` CRD isn't magic either: `manifests/unsecured/sandbox/`
shows the same reckless posture via the CRD — see below.)

## Prerequisites

- [`kind`](https://kind.sigs.k8s.io/) + Podman
- `kubectl`
- Internet access (pulls Calico, the controller manifest, and the demo image)

> **Note:** your container runtime (and therefore this kind
> cluster) runs inside a Linux VM. The isolation this lab *demonstrates* is the
> in-cluster Kubernetes posture — not the incidental VM boundary your laptop
> gets for free. On a real Linux node there is no such VM. See
> [`manifests/gvisor/`](manifests/gvisor/).

## Run it

```bash
cd lab
./scripts/preflight-kvm.sh         # (optional) what isolation can this machine run?
./scripts/01-up.sh                 # kind + Calico CNI + agent-sandbox controller (~3-4 min)
./scripts/02-attack-unsecured.sh   # deploy a plain Pod (defaults); watch it get owned
./scripts/03-defend-secured.sh     # deploy the hardened Sandbox; watch attacks bounce
./scripts/03b-defend-secured-template.sh  # same, but via a reusable SandboxTemplate
./scripts/99-down.sh               # delete the cluster
```

`./scripts/demo.sh` runs the unsecured breach → secured containment → template
containment back-to-back (with pauses) — handy for presenting live.

**Stronger isolation (optional):**

```bash
WITH_GVISOR=1 ./scripts/01-up.sh   # install runsc into the VM + register the gvisor RuntimeClass
./scripts/04-harden-gvisor.sh      # run a Sandbox under gVisor; prove uname -> *-gvisor
./scripts/05-compare-gvisor.sh     # same hardened spec, runc vs gVisor: what gVisor adds
./scripts/06-vm-proof.sh           # from the node: runc shares its kernel, gVisor doesn't
```

For the VM‑based tiers (Kata, Firecracker — need `/dev/kvm`, i.e. a Linux/EC2
host) see [`manifests/kata/`](manifests/kata/) (validated end‑to‑end on an EC2
`m7i` via `manifests/kata/validate-kind.sh`) and [`manifests/firecracker/`](manifests/firecracker/).

## What you should see

**Unsecured** — every probe is a `⚠ BREACH`:

```
▶ PROBE: Read a secret from the 'corp-secrets' namespace via the Kubernetes API
  ⚠ BREACH: exfiltrated prod DB credentials: prod-admin / S3cr3t-pr0d-DB-p@ssw0rd-do-not-leak
▶ PROBE: Read the cluster CA private key from the node's filesystem
  ⚠ BREACH: node root is mounted at /host — read /etc/kubernetes/pki/ca.key ...
▶ PROBE: List host processes (control-plane components) from inside the pod
  510 kube-apiserver   604 etcd   661 kubelet
  ⚠ BREACH: host PID namespace shared ...
▶ PROBE: Check in-container identity and filesystem
  ⚠ BREACH: running as root with a writable root filesystem
```

**Secured** — the same probes are all `🛡 CONTAINED`:

```
▶ PROBE: Read a secret ... via the Kubernetes API
  🛡 CONTAINED: no service-account token is mounted — the agent has no cluster credential
▶ PROBE: Read the cluster CA private key from the node's filesystem
  🛡 CONTAINED: no hostPath mount — /host does not exist, node filesystem is invisible
▶ PROBE: List host processes ...
  🛡 CONTAINED: own PID namespace — the agent sees only its own ~5 processes
▶ PROBE: Check in-container identity and filesystem
  🛡 CONTAINED: running as non-root (uid 65532)
  🛡 CONTAINED: root filesystem is read-only
▶ PROBE: Reach the Kubernetes API server over the network (bypassing the token)
  🛡 CONTAINED: egress blocked by NetworkPolicy
```

### But the hardened default still shares the host kernel

The secured pod above blocks the obvious attacks — yet it is **still running on
the node's real kernel**. That residual attack surface is what gVisor removes,
and `./scripts/05-compare-gvisor.sh` proves it by running the **exact same
hardened spec** on runc vs under gVisor (run `WITH_GVISOR=1 ./scripts/01-up.sh`
first). Verified output:

```
▶ PROBE: Which kernel is the agent actually running on? (uname -r)
    runc:      6.17.7-300.fc43.aarch64      <- the node's real kernel
    gvisor:    4.19.0-gvisor                <- gVisor's own userspace kernel
▶ PROBE: Enumerate the node's loaded kernel modules (ls /sys/module | wc -l)
    runc:      242                          <- every host kernel module is visible
    gvisor:    0                            <- none; there is no host kernel to see
▶ PROBE: Invoke io_uring, a kernel-escape-prone subsystem — is it even there?
    runc:      REACHED the host kernel's io_uring subsystem (errno=EFAULT)
    gvisor:    ENOSYS - no io_uring in this kernel; the subsystem is not reachable
```

So, under the **hardened runc default**, untrusted agent code can still read the
node's exact kernel version, enumerate all 242 of its loaded modules, and invoke
`io_uring` — the host kernel subsystem behind numerous container-escape CVEs. A
single kernel bug there is a real escape path. Under **gVisor**, the agent talks
to `runsc`'s reimplemented kernel: no host kernel version, no host modules, and
`io_uring` returns `ENOSYS` — the subsystem does not exist to attack. **That is
the concrete thing gVisor adds over the default**, and the only change is one
line: `runtimeClassName: gvisor`.

### Manual proof: SSH into the node and look for yourself

The container's own report ("I'm on kernel 6.x") could be a lie. So prove it
from the outside. On macOS the kind node runs inside the **podman Linux VM** —
which stands in for a production Linux **node**. `./scripts/06-vm-proof.sh`
automates the SSH walkthrough; here it is by hand:

```bash
podman machine ssh            # into the VM == the node
sudo bash
uname -r                      # 6.17.7-...  — the node's kernel

# find the runc agent — it's just an ordinary process on the node:
for p in $(pgrep -x sleep); do echo "$p $(cat /proc/$p/root/etc/hostname 2>/dev/null)"; done
# -> e.g. "1310480 secured-agent"

# the node reads straight INTO the container's filesystem (no isolation):
cat /proc/1310480/root/etc/hostname      # -> secured-agent
ls  /proc/1310480/root                   # the container's whole rootfs
#   (the node could kill -9 it or write to those files, too)
```

Verified output — the node and the runc container share **one** kernel, and the
node can see and read into the container:

```
VM / node kernel (uname -r): 6.17.7-300.fc43.aarch64
found the runc agent at VM pid 1310480:
   1310480 1310394 sleep  sleep infinity          (parent: containerd-shim)
   # cat /proc/1310480/root/etc/hostname  -> secured-agent
   # ls  /proc/1310480/root               -> bin dev etc home ... usr var
```

Now do the same for the gVisor pod — and it isn't there:

```
host 'sleep' processes belonging to the gVisor pod: 0   (expected 0)
what the node sees instead is the runsc sandbox:
   gvisor_sentry  runsc-sandbox ... boot ...
   runsc-gofer    ...
```

The gVisor agent is **not** a normal process on the node: its `sleep` never
appears, and the node cannot `/proc/<pid>/root` into it. All the node sees is
`gvisor_sentry` — the userspace kernel that owns the agent's syscalls and
filesystem.

> **The point for macOS users:** the podman VM only isolates containers from
> **your laptop**. *Inside* the VM — i.e. on a real Linux node — a plain runc
> container is wide open to the node. gVisor (or Kata/Firecracker) is what adds
> the node-level isolation that Kubernetes does **not** give you by default.

## How it maps to the attacks (defense in depth)

| Attack | What stops it (secured) |
|---|---|
| Steal creds via API token | `automountServiceAccountToken: false` + zero-RBAC ServiceAccount |
| Read the node filesystem | no `hostPath` mount, not `privileged` |
| See/kill host processes | no `hostPID` (own PID namespace) |
| Regain privileges / tamper | `runAsNonRoot`, `allowPrivilegeEscalation: false`, drop `ALL` caps, `readOnlyRootFilesystem`, seccomp `RuntimeDefault` |
| Reach API / kubelet / metadata over the network | deny-all egress `NetworkPolicy` (DNS only), enforced by Calico |
| Exhaust the node | `resources.requests/limits` |

No single control is sufficient — they **layer**. Add
`runtimeClassName: gvisor` (see below) to also shrink the shared-kernel attack
surface.

## Files

```
lab/
├── kind-config.yaml              # cluster: Calico CNI so NetworkPolicy is enforced
├── manifests/
│   ├── 00-setup.yaml             # namespaces + the "loot" secret in corp-secrets
│   ├── unsecured/                # plain-K8s Pod (defaults) + admin RBAC; sandbox/ = same via the CRD
│   ├── secured/                  # hardened bare Sandbox; secured/template/ = same via SandboxTemplate
│   ├── gvisor/                   # kernel-level isolation — RUNS ON THIS MAC (no KVM)
│   ├── kata/                     # microVM isolation — needs /dev/kvm (Linux/cloud)
│   └── firecracker/              # microVM isolation — needs /dev/kvm (Linux/cloud)
└── scripts/
    ├── lib.sh                    # shared helpers
    ├── 01-up.sh  02-attack-unsecured.sh  03-defend-secured.sh
    ├── 03b-defend-secured-template.sh   # secured via a reusable SandboxTemplate
    ├── 04-harden-gvisor.sh       # deploy a Sandbox under gVisor + prove it
    ├── 05-compare-gvisor.sh      # same spec on runc vs gVisor: what gVisor adds
    ├── 06-vm-proof.sh            # SSH into the node: runc shares its kernel, gVisor doesn't
    ├── install-runsc.sh          # install gVisor runsc into the podman VM
    ├── preflight-kvm.sh          # can this machine run Kata/Firecracker?
    ├── demo.sh   99-down.sh
```

## Why the `Sandbox` CRD and not raw YAML?

You *could* assemble this from a size-1 StatefulSet + headless Service + PVC +
ServiceAccount/RBAC + NetworkPolicy + `securityContext` + `RuntimeClass`, plus
your own lifecycle and warm-pool glue. That is a lot of moving parts and easy to
get insecure. The `Sandbox` CRD collapses it into one declarative object with a
stable identity, persistence, lifecycle management, and (via `SandboxTemplate`)
secure defaults and pre-warmed pools for fast allocation. Same workload, one
object, consistent and reusable.

**Secure by construction:** [`manifests/secured/template/`](manifests/secured/template/)
recasts the secured path as a reusable **`SandboxTemplate`** (consumed via a
`SandboxWarmPool` + `SandboxClaim`). The template controller then provides two
controls *for free* — `automountServiceAccountToken: false` by default and a
managed deny‑by‑default NetworkPolicy — while the `securityContext`/caps/seccomp
hardening is authored once in the template and inherited by every claim. (The
core `Sandbox` CRD adds **no** hardening on its own; see that folder's README.)

## Stronger isolation: swapping the runtime (one line)

The controls above are Kubernetes-native and still **share the host kernel**.
For kernel/hardware-level isolation, run the Sandbox under a secure runtime via
`runtimeClassName` — the *only* change to the workload. The `Sandbox` CRD passes
it straight through, so you pick your isolation tier without touching the agent.

| Tier | Runtime | Boundary | `/dev/kvm`? | On this M2 Pro Mac |
|---|---|---|---|---|
| Hardening | `runc` (default) + securityContext | shared kernel | no | ✅ the core lab |
| Process-level | **gVisor** (`runsc`) | userspace kernel | **no** | ✅ **runs here** |
| Hardware | **Kata** (`kata-qemu`) | guest kernel in a VM | yes | ❌ no KVM |
| Hardware | **Firecracker** (`kata-fc`) | microVM | yes | ❌ no KVM |

Check your machine: `./scripts/preflight-kvm.sh`.

- **gVisor — runs on this Mac.** `runsc`'s systrap platform needs no KVM, so it
  works inside the podman VM:
  ```bash
  WITH_GVISOR=1 ./scripts/01-up.sh   # installs runsc into the VM, registers the RuntimeClass
  ./scripts/04-harden-gvisor.sh      # Sandbox under gVisor; proves uname -> *-gvisor, ~17 /dev nodes
  ```
  See [`manifests/gvisor/README.md`](manifests/gvisor/README.md).
- **Kata / Firecracker — need `/dev/kvm`.** Apple M1/M2 can't expose it (nested
  virt needs M3+/macOS 15+), so run these on a bare-metal Linux host or a cloud
  node pool. Full, runnable instructions:
  [`manifests/kata/README.md`](manifests/kata/README.md) ·
  [`manifests/firecracker/README.md`](manifests/firecracker/README.md).

> Stronger isolation = slower cold start. In production you hide that latency
> with a `SandboxWarmPool` (pre-warmed Sandboxes), so you get both strong
> isolation *and* fast allocation.
