# Appendix: microVM isolation with Firecracker

[Firecracker](https://firecracker-microvm.github.io/) is a minimal **Virtual
Machine Monitor (VMM)** built for serverless workloads — it powers **AWS Lambda
and Fargate**. It boots a stripped-down microVM (just virtio-net, virtio-block,
a serial console — no BIOS, no PCI, no full device model) in **~125 ms**, with a
few MB of memory overhead. That minimal device model is itself a security
feature: a tiny attack surface between guest and host.

Like Kata, Firecracker gives each pod a **real guest kernel** behind a
**hardware-virtualized boundary**, so it is in the strongest isolation tier
alongside Kata/QEMU — but optimized for **density and fast boot** rather than
device completeness.

## Hard requirement: `/dev/kvm` (Linux + KVM only)

Firecracker is **Linux/KVM-only**. Run `./scripts/preflight-kvm.sh` first.

- **macOS (this workstation):** no `/dev/kvm` inside the podman VM on Apple M1/M2
  → **Firecracker cannot run here.** Use gVisor for on-Mac hardening
  (`WITH_GVISOR=1 ./scripts/01-up.sh`), and run Firecracker on a Linux host or
  a bare-metal cloud instance (e.g. AWS `*.metal`).
- **On AWS EC2:** Firecracker's own docs recommend a bare-metal Linux instance
  (`c5.metal` + Ubuntu) for native `/dev/kvm` and full microVM performance. A
  nested-virtualization *virtual* instance also works for a functional demo —
  see [`../kata/README.md` → "On AWS EC2"](../kata/README.md). **Not** an EC2
  Mac instance (that's macOS; it would need a nested Linux VM detour).
- **On kind (even on a KVM host): no, without extra work.** Validated on an EC2
  `m7i` (nested virt): a `Sandbox` with `runtimeClassName: kata-fc` fails with
  `could not find snapshotter devmapper plugin` — kind's containerd uses
  overlayfs, and Firecracker needs a **devmapper** (block-device) snapshotter.
  On that same kind cluster, **Cloud Hypervisor (`kata-clh`) booted a real
  microVM successfully** (guest kernel ≠ host) — so for a microVM demo on kind,
  use `kata-clh`; use Firecracker on a host whose containerd has devmapper
  configured. See [`../kata/README.md` → "What actually works where (validated)"](../kata/README.md).

## Two ways to run Firecracker under Kubernetes

### 1. Via Kata Containers (recommended, `runtimeClassName: kata-fc`)

The simplest Kubernetes path: install Kata (see [`../kata/`](../kata/)), which
can drive **Firecracker as its hypervisor**. This requires containerd's
**devmapper** snapshotter (Firecracker needs block-device rootfs, not overlayfs):

```bash
# 1) Configure the containerd devmapper snapshotter on each node (one-time).
#    See: https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-use-virtio-fs-with-firecracker.md
# 2) Install kata-deploy (see ../kata/README.md).
# 3) Use the kata-fc RuntimeClass:
kubectl apply -f manifests/firecracker/runtimeclass.yaml
```

```yaml
spec:
  podTemplate:
    spec:
      runtimeClassName: kata-fc   # Kata driving the Firecracker VMM
      automountServiceAccountToken: false
      containers:
        - name: agent
          image: nicolaka/netshoot:v0.13
          command: ["sleep", "infinity"]
```

### 2. Via firecracker-containerd (standalone)

[`firecracker-containerd`](https://github.com/firecracker-microvm/firecracker-containerd)
is AWS's containerd runtime that runs each container in its own Firecracker
microVM directly (no Kata). It's the lowest-level option and what serverless
platforms build on; expect more manual setup (devmapper, a jailer, a microVM
root filesystem image). Use it when you want Firecracker without Kata's layer.

## Verify

```bash
POD=... ; NS=agent-sandbox-demo
kubectl -n $NS get pod $POD -o jsonpath='{.spec.runtimeClassName}'; echo   # kata-fc
kubectl -n $NS exec $POD -- uname -r     # guest kernel inside the microVM
```

## Pros / cons

| | Firecracker (microVM) |
|---|---|
| Isolation | **Strong** — guest kernel + hardware boundary |
| Boot time | **~125 ms** VMM start — fastest VM-based option |
| Density | Very high — minimal per-VM memory overhead (built for multi-tenant) |
| Device model | Intentionally **minimal** (virtio-net/block/serial only) — small attack surface, but less hardware compatibility |
| Needs | Linux + `/dev/kvm`; devmapper snapshotter; bare-metal or nested-virt host |

## Where this fits the lecture

Firecracker is the concrete answer to "how do serverless platforms run millions
of tiny untrusted workloads safely and cheaply?" — strong VM isolation with
near-container start times. Combine it with **warm pools** (`SandboxWarmPool`)
to erase even the ~125 ms, and the `Sandbox` CRD makes switching tiers a
one-line `runtimeClassName` change.
