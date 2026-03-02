# Pod Security

Reference: [AWS EKS Best Practices: Pod Security](https://docs.aws.amazon.com/eks/latest/best-practices/pod-security.html)

---

## Implemented Practices

### 1. Pod Security Admission on Customer Namespaces

**File:** `gitops/apps/aws/staging/acme/namespace.yaml`

```yaml
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/warn: restricted
pod-security.kubernetes.io/audit: restricted
```

**What it does:**
The `restricted` Pod Security Standard is the strictest built-in Kubernetes policy. It
requires every pod in the namespace to:
- Run as a non-root user
- Disable privilege escalation (`allowPrivilegeEscalation: false`)
- Drop all Linux capabilities
- Use a `RuntimeDefault` or `Localhost` seccomp profile
- Not use hostPath volumes, hostPID, hostNetwork, or hostIPC

All three modes are set together:
- `enforce` - pods that violate the policy are rejected at admission
- `warn` - a warning is returned when a Deployment or other controller violates the policy
- `audit` - violations are recorded in the audit log

Setting all three catches violations at every level: the controller (warn/audit) and the
pod itself (enforce).

**Why:**
Every customer namespace in this platform runs application workloads that do not need
elevated host privileges. The `restricted` profile is the correct baseline for any
production application namespace because it removes the most common container escape
vectors: privilege escalation, dangerous capabilities, and access to the host process or
network namespace.

This label is part of the customer namespace template. Every new customer namespace added
to the platform should carry these labels.

---

### 2. Pod Security Admission on the Shared Gateway Namespace

**File:** `gitops/infrastructure/configs/base/gateway/namespace.yaml`

```yaml
pod-security.kubernetes.io/enforce: baseline
pod-security.kubernetes.io/warn: restricted
pod-security.kubernetes.io/audit: restricted
```

**What it does:**
Applies the `baseline` standard in enforce mode to block the most dangerous pod
configurations (privileged containers, host namespace access, unsafe volume types).
The `restricted` standard is applied in warn/audit only to surface violations without
blocking workloads.

**Why:**
cert-manager creates short-lived HTTP01 solver pods in `shared-gateway` during certificate
issuance. These pods are managed by cert-manager and may not declare the full securityContext
required by `restricted` (e.g. seccompProfile). Using `baseline` in enforce mode is the
right compromise: it blocks privilege abuse without breaking certificate issuance.
`restricted` in warn/audit provides visibility for future policy tightening.

---

### 3. Container Security Context - Platform Template

**File:** `gitops/apps/aws/staging/acme/values.yaml`

```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile:
    type: RuntimeDefault

securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
  readOnlyRootFilesystem: true

extraVolumes:
  - name: app-data
    emptyDir: {}
  - name: tmp
    emptyDir: {}

extraVolumeMounts:
  - name: app-data
    mountPath: /home/node/.n8n
  - name: tmp
    mountPath: /tmp
```

**What it does:**
This is the standard securityContext template that every customer application workload
should include. Each field has a specific purpose:

- `runAsNonRoot: true` - the container process cannot start as UID 0
- `runAsUser/Group` - set to the non-root UID/GID the application image uses
- `seccompProfile: RuntimeDefault` - applies the container runtime's built-in syscall
  allowlist, blocking a large number of dangerous system calls
- `allowPrivilegeEscalation: false` - prevents any process from gaining more privileges
  than its parent (no setuid/setgid, no sudo)
- `capabilities.drop: [ALL]` - removes every Linux capability; standard web/worker
  applications require none
- `readOnlyRootFilesystem: true` - the container filesystem is mounted read-only;
  attackers cannot overwrite application binaries or write scripts to disk
- `emptyDir` volumes for `/tmp` and the app data directory provide writable scratch space
  without exposing the host filesystem

**Why:**
These settings together satisfy the PSA `restricted` policy enforced at the namespace
level. Beyond satisfying the policy, each setting provides independent defense-in-depth. A
compromised application container that cannot escalate privileges, use capabilities, or
write to the root filesystem is significantly harder to use as a persistent foothold or
lateral movement vector.

This block is the reference template for any new customer application onboarded to the
platform. The `runAsUser` value and the writable mount paths will differ per application
image, but the security fields remain constant.

---

### 4. Resource Requests and Limits - Platform Template

**File:** `gitops/apps/aws/staging/acme/values.yaml`

```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

**What it does:**
Sets CPU and memory guarantees (requests) and ceilings (limits) on the application
container. This places pods in the `Burstable` QoS class (requests < limits).

**Why:**
Without resource limits, a single misbehaving or compromised application instance can
consume all memory on a node, triggering OOM eviction of other pods. In a multi-tenant
cluster this affects all customers on the same node. Resource limits bound the blast radius
of both accidental bugs (memory leaks, runaway loops) and deliberate resource exhaustion
attempts.

Requests ensure the pod is scheduled only onto a node with enough available capacity,
preventing the pod from starting in a state where it will immediately be OOM-killed.
The values shown are conservative starting points; each customer application should tune
them based on observed usage from monitoring.

---

## Not Applicable

- **Docker-in-Docker (Practice 10):** No CI/CD workloads run in this cluster.
- **hostPath restriction:** Already blocked by the PSA `restricted` and `baseline` labels.

---

## Future Work

- **Tighten `shared-gateway` to `restricted` enforce:** Once cert-manager solver pods are
  confirmed to include `seccompProfile` and `capabilities.drop`, upgrade enforce from
  `baseline` to `restricted`.
- **PSA labels on infrastructure namespaces:** Add `baseline` enforce labels to
  `cert-manager`, `cnpg-system`, and `flux-system`. Requires verifying controller
  securityContext compatibility first.
- **Policy-as-code (Kyverno):** For auto-injecting securityContext into pods that do not
  declare it and for rules that go beyond what PSA supports, consider adding Kyverno as a
  Flux-managed HelmRelease.
