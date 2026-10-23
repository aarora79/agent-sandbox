# Secure by construction: the `SandboxTemplate` path

The sibling `../sandbox.yaml` + `../networkpolicy.yaml` + `../rbac.yaml` harden a
**bare `Sandbox`** — every line is written by hand because the core `Sandbox`
controller passes your Pod spec through verbatim (it adds **no** defaults).

This folder does the same thing the **reusable** way: one `SandboxTemplate`
holds the whole posture, and every `SandboxClaim` inherits it. Two controls then
come **for free** from the SandboxTemplate controller — you don't author them:

| Control | Bare `Sandbox` (`../`) | `SandboxTemplate` (here) |
|---|---|---|
| `automountServiceAccountToken: false` | you set it | **free** — defaulted to false when omitted |
| deny‑by‑default NetworkPolicy | you apply `../networkpolicy.yaml` | **free** — minted from the `networkPolicy:` block |
| `runAsNonRoot` / drop `ALL` caps / `readOnlyRootFilesystem` / seccomp | you set it | **still you** — authored once in the template |
| resource limits | you set it | **still you** — in the template |
| gVisor/Kata runtime | you set `runtimeClassName` | **still you** — in the template |

So a `SandboxTemplate` doesn't make security automatic — it makes it **authored
once and reused**, and it hands you the token + network defaults.

## Run it (needs `./scripts/01-up.sh` — extensions controller + Calico)

One command runs the whole thing and re-runs the same containment probes as
`03-defend-secured.sh`:

```bash
./scripts/03b-defend-secured-template.sh
```

Or by hand — `SandboxClaim` can only reference a warm pool, so the path is
**Template → WarmPool → Claim**:

```bash
kubectl apply -f manifests/secured/template/sandboxtemplate.yaml \
               -f manifests/secured/template/sandboxwarmpool.yaml \
               -f manifests/secured/template/sandboxclaim.yaml

kubectl -n agent-sandbox-demo wait --for=condition=Ready sandboxclaim/secured-claim --timeout=180s
POD=$(kubectl -n agent-sandbox-demo get sandboxclaim secured-claim -o jsonpath='{.status.sandbox.name}')
```

## Verify (observed output)

```text
token mounted?         no token (automount=false)          # template default
id                     uid=65532 gid=65532 groups=65532
write /malware         Read-only file system
ls /host               No such file or directory
curl https://kubernetes.default.svc/   egress blocked       # managed NetworkPolicy
kubectl get networkpolicy
  secured-template-network-policy  policyTypes=[Ingress,Egress]
                                   ingress=<none> (deny all)   egress=DNS :53 only
pod spec: automount=false  seccomp=RuntimeDefault  runAsNonRoot=true
          caps.drop=[ALL]  readOnlyRootFilesystem=true
```

## Notes

- The managed NetworkPolicy selects **all pods from this template**
  (`agents.x-k8s.io/sandbox-template-ref-hash`), not one pod — a shared,
  default‑deny policy. It still needs a policy‑enforcing CNI (Calico; kindnet
  ignores it). Enforcement confirmed above (egress to the API server times out).
- The warm pool pre‑creates the sandbox so the claim resolves instantly; bump
  `replicas` in `sandboxwarmpool.yaml` for a bigger pool.
- Add kernel‑level isolation by uncommenting `runtimeClassName: gvisor` in
  `sandboxtemplate.yaml` (needs `runsc` on the node — `WITH_GVISOR=1 ./scripts/01-up.sh`).
