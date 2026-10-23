# Appendix: hardware isolation with Kata Containers

Kata runs each pod inside a **lightweight virtual machine with its own guest
kernel**, managed by a hypervisor (QEMU by default). The isolation boundary is
**virtual hardware**, enforced by the CPU (VT-x/AMD-V) — a container escape has
to escape a VM, not just the shared Linux kernel. Cost: ~a few hundred MB and
~seconds of extra startup per pod.

In Kubernetes you select it per-pod with `runtimeClassName: kata-qemu`. The
`agent-sandbox` `Sandbox` CRD passes that straight through — the workload is
unchanged.

## Hard requirement: `/dev/kvm`

Kata needs **hardware virtualization exposed as `/dev/kvm`**. Check your machine:

```bash
./scripts/preflight-kvm.sh
```

- **Bare-metal Linux / cloud VMs with nested virt** → works.
- **macOS (this lab's workstation)** → the container runtime runs inside the
  podman VM, so Kata would need **nested** virtualization *inside* that VM. On
  Apple silicon that needs **M3+ and macOS 15+** with a hypervisor that exposes
  it; **M1/M2 cannot**. On the M2 Pro this repo was built on, `preflight-kvm.sh`
  reports no `/dev/kvm` → **Kata cannot run here. Use gVisor instead.**

So: run this section on a **Linux host with KVM** or a **cloud node pool**, not
on an Apple-silicon Mac.

### What actually works where (validated)

| Platform | Result |
|---|---|
| **Mac, kind + podman** | ❌ no `/dev/kvm` in the podman VM → the microVM can't boot. The `Sandbox` CRD still propagates `runtimeClassName` to the pod correctly; only the VM layer is missing. Use **gVisor** on a Mac. |
| **KVM Linux host (EC2 `m7i` nested virt, or any `*.metal`), kind** | ✅ **Validated end-to-end** — `kata-deploy` installs, the `Sandbox` boots a real microVM. kind keeps kube-proxy/CNI in the node's netns, so it does **not** disturb host networking/SSH. |

Validated on an EC2 `m7i.2xlarge` (nested virt, Amazon Linux 2023, kernel
`6.18.54`) running the **same** `Sandbox` under different Kata VMMs via kind:

| `runtimeClassName` | Result on kind + nested virt |
|---|---|
| **`kata-clh`** (Cloud Hypervisor) | ✅ **Running** — guest kernel `6.18.35` ≠ host `6.18.54`; guest `dmesg` shows `DMI: Cloud Hypervisor` / `Hypervisor detected: KVM`; ~15 `/dev` nodes. |
| `kata-qemu`, `kata-qemu-runtime-rs` | ❌ `kvm run failed Bad address` — QEMU's default `-machine …,nvdimm=on -cpu host` doesn't survive **nested** KVM. |
| `kata-fc` (Firecracker) | ❌ `could not find snapshotter devmapper plugin` — Firecracker needs a block **devmapper** snapshotter; kind's containerd uses overlayfs. |

**Takeaways for the lab:**
- To demo Kata on kind on a KVM host, use **`runtimeClassName: kata-clh`** — it's
  the microVM tier and sidesteps qemu's nested-virt crash. Reproduce with
  [`validate-kind.sh`](validate-kind.sh).
- `kata-qemu` is fine on **bare metal** (no nesting); for nested VMs prefer `kata-clh`.
- Firecracker needs the **devmapper** snapshotter in containerd (see
  [`../firecracker/`](../firecracker/)) — not present in a stock kind node.

> The Mac blocker is simply **no `/dev/kvm`** (podman exposes none, and there's no
> podman knob even on M3/M4). So Kata/Firecracker can't run on a Mac regardless;
> gVisor is the on-Mac option. The earlier assumption that "kind can't host Kata"
> was wrong — on a KVM-capable Linux host, kind runs it fine (validated above).

## Install (Linux host with KVM)

The supported path is **`kata-deploy`**, which installs the Kata binaries onto
each node and registers the containerd runtimes + RuntimeClasses.

```bash
# Label the nodes you want Kata on (kata-deploy targets all by default):
kubectl apply -f https://raw.githubusercontent.com/kata-containers/kata-containers/main/tools/packaging/kata-deploy/kata-rbac/base/kata-rbac.yaml
kubectl apply -f https://raw.githubusercontent.com/kata-containers/kata-containers/main/tools/packaging/kata-deploy/kata-deploy/base/kata-deploy.yaml

# Wait for the installer to finish on every node:
kubectl -n kube-system rollout status ds/kata-deploy

# kata-deploy creates the RuntimeClasses (kata-qemu, kata-clh, kata-fc, ...).
# They are also mirrored here for reference:
kubectl apply -f manifests/kata/runtimeclass.yaml
kubectl get runtimeclass | grep kata
```

> On a local Linux box you can get a KVM-backed cluster with **minikube**
> (`minikube start --driver kvm2 --memory 8192`) and run `kata-deploy` inside
> it. Plain `kind` nodes are containers and generally cannot host Kata VMs.

### GKE / managed clusters

Managed options exist (e.g. **GKE Sandbox** historically used gVisor; some
providers offer Kata/Confidential nodes). Create a node pool whose nodes support
nested virtualization, then run `kata-deploy` the same way.

### On AWS EC2 (the practical cloud path)

> Not lab-tested from this repo's workstation (no AWS access here); the steps
> below are grounded in the AWS, Kata, and Firecracker docs. Pick ONE host:

**Option A — bare-metal Linux (native KVM, recommended for Firecracker).**
Any Linux `*.metal` instance exposes `/dev/kvm` directly. Firecracker's own
getting-started uses `c5.metal` + Ubuntu. Arm? use a Graviton `*.metal`
(`c7g.metal`, `m7g.metal`).

```bash
aws ec2 run-instances --image-id <ubuntu-24.04-ami> \
  --instance-type c5.metal --key-name <key> # native /dev/kvm, no extra flag
```

**Option B — virtual (non-metal) Linux instance with nested virtualization**
(cheaper than metal; great for a Kata functional demo). Supported on **Intel**
families only — M7i/M8i, C7i/C8i, R7i/R8i, X8i, I7i (VT-x); Graviton/Arm is NOT
supported, use Option A there.

```bash
# enable at launch:
aws ec2 run-instances --image-id <ubuntu-24.04-ami> \
  --instance-type m7i.2xlarge --key-name <key> \
  --cpu-options "NestedVirtualization=enabled"

# confirm a type supports it before launching:
aws ec2 describe-instance-types --instance-types m7i.2xlarge \
  --query "InstanceTypes[].ProcessorInfo.SupportedFeatures"   # includes "nested-virtualization"
```

On the instance, confirm KVM, bring up a single-node cluster on the host (kind
nodes are containers and can't host Kata VMs), then run `kata-deploy` as above:

```bash
ls -l /dev/kvm                      # must exist (preflight-kvm.sh checks this)
minikube start --driver=none        # or k3s — runs k8s directly on the host's kernel + /dev/kvm
```

> **Not an EC2 Mac.** EC2 Mac instances (incl. `mac-m4.metal`) are macOS on
> bare metal for building/testing Apple software. Running Kata/Firecracker there
> would mean a Linux VM using Apple **nested virtualization** (M3/M4 + macOS 15,
> Linux guests only, tooling still immature) — a slow, 4-layer detour. Use a
> Linux instance (Option A/B) instead.

## Use it with a Sandbox

Point the hardened Sandbox at Kata — one line changes vs `../secured/sandbox.yaml`:

```yaml
spec:
  podTemplate:
    spec:
      runtimeClassName: kata-qemu   # <- the only change; same workload
      automountServiceAccountToken: false
      securityContext: { runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: agent
          image: nicolaka/netshoot:v0.13
          command: ["sleep", "infinity"]
```

Verify the pod really booted a VM:

```bash
POD=... ; NS=agent-sandbox-demo
kubectl -n $NS get pod $POD -o jsonpath='{.spec.runtimeClassName}'; echo   # kata-qemu
kubectl -n $NS exec $POD -- uname -r      # a Kata GUEST kernel, different from the node's
kubectl -n $NS exec $POD -- sh -c 'dmesg | head'   # guest kernel boot log
```

## Pros / cons

| | Kata (`kata-qemu`) |
|---|---|
| Isolation | **Strong** — real guest kernel + virtual hardware boundary |
| Compatibility | High — OCI/CRI compatible, full syscall surface (unlike gVisor) |
| Startup | ~seconds (boots a kernel) — hide it with a **SandboxWarmPool** |
| Overhead | ~hundreds of MB + CPU per pod |
| Needs | `/dev/kvm` (hardware virt) |

See [`../firecracker/`](../firecracker/) for the Firecracker VMM variant
(`kata-fc`), which trades device-model richness for a much smaller/faster microVM.
