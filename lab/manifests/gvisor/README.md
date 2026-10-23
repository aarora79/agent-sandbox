# gVisor: kernel-level isolation that runs on your Mac

The core lab hardens the sandbox with **Kubernetes-native** controls (identity,
`securityContext`, `NetworkPolicy`). Those still share the **host kernel** — a
kernel exploit is still a possible escape path.

**gVisor** closes that gap. `runsc` is a **userspace kernel**: it intercepts the
container's syscalls and services them itself, so the real host kernel is barely
exposed. Crucially for this lab, gVisor's default **`systrap` platform needs no
KVM**, so — unlike Kata and Firecracker — **it actually runs inside the podman
VM on an Apple-silicon Mac.**

## Run it (works on this M2 Pro Mac)

```bash
# 1) Install runsc into the podman VM + bring the cluster up with the gVisor
#    containerd runtime and a 'gvisor' RuntimeClass registered:
WITH_GVISOR=1 ./scripts/01-up.sh

# 2) (optional) run the baseline unsecured/secured demo exactly as before:
./scripts/02-attack-unsecured.sh
./scripts/03-defend-secured.sh

# 3) Deploy a Sandbox UNDER gVisor and prove the kernel is virtualized:
./scripts/04-harden-gvisor.sh

# 4) Prove what gVisor adds OVER the hardened default (same spec, runc vs gVisor):
./scripts/05-compare-gvisor.sh

# 5) Manual proof from the node itself (SSH into the VM):
./scripts/06-vm-proof.sh
```

`01-up.sh` with `WITH_GVISOR=1` runs [`../../scripts/install-runsc.sh`](../../scripts/install-runsc.sh)
(downloads `runsc` + `containerd-shim-runsc-v1` + the `gvisor-bin/` sidecars into
the VM), creates the cluster from [`kind-config.yaml`](kind-config.yaml) (which
bind-mounts those binaries into the node and patches containerd), then applies
[`runtimeclass.yaml`](runtimeclass.yaml).

The only workload change is one line — see [`sandbox-gvisor.yaml`](sandbox-gvisor.yaml):

```yaml
spec:
  podTemplate:
    spec:
      runtimeClassName: gvisor   # syscalls go to runsc, not the host kernel
```

## Why this is possible on Mac when Kata/Firecracker are not

| | gVisor (`runsc`) | Kata / Firecracker |
|---|---|---|
| Boundary | userspace kernel (syscall intercept) | guest kernel in a VM |
| Needs `/dev/kvm`? | **No** (systrap/ptrace platform) | **Yes** (hardware virt) |
| Runs in the podman VM on M1/M2? | **Yes** | No (needs nested virt: M3+/macOS 15+) |

Run `./scripts/preflight-kvm.sh` to see the KVM verdict for your machine, and
see [`../kata/`](../kata/) and [`../firecracker/`](../firecracker/) for the
microVM tiers (run those on a KVM-capable Linux host or cloud node pool).

## Linux hosts

On a Linux workstation you don't need the VM install — install gVisor on the
host per the [official guide](https://gvisor.dev/docs/user_guide/install/) so
`/usr/local/bin/runsc` exists, then `WITH_GVISOR=1 ./scripts/01-up.sh` mounts it
into the kind node the same way.
