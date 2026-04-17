# Runtime Security

Reference: [AWS EKS Best Practices: Runtime Security](https://docs.aws.amazon.com/eks/latest/best-practices/runtime-security.html)

See [best-practices-traceability.md](best-practices-traceability.md) for a table mapping every best practice to the exact file and config.


## Implemented Practices

### 1. Amazon GuardDuty with EKS Runtime Monitoring

**File:** `provision/aws/cloudformation/eks.yaml`

```yaml
GuardDutyDetector:
  Type: AWS::GuardDuty::Detector
  Properties:
    Enable: true
    FindingPublishingFrequency: SIX_HOURS
    Features:
      - Name: EKS_AUDIT_LOGS
        Status: ENABLED
      - Name: EKS_RUNTIME_MONITORING
        Status: ENABLED
        AdditionalConfiguration:
          - Name: EKS_ADDON_MANAGEMENT
            Status: ENABLED
```

**What it does:**

GuardDuty provides two complementary detection layers for EKS:

**EKS_AUDIT_LOGS** - GuardDuty ingests and analyses the Kubernetes audit log stream directly from EKS (no CloudWatch configuration required). It applies continuously updated threat intelligence and machine learning models to detect control-plane threats such as:
- Privilege escalation (e.g., a pod creating ClusterRoleBindings for itself)
- Exposed credentials being used from unexpected IPs
- Anomalous API calls that deviate from the workload's baseline behaviour
- Use of the Kubernetes exec API to shell into containers

**EKS_RUNTIME_MONITORING** - GuardDuty deploys an eBPF-based sensor on each node as an EKS add-on (`aws-guardduty-agent` DaemonSet in the `amazon-guardduty` namespace). The sensor observes system calls at the kernel level without modifying the container or requiring a sidecar. It detects:
- Unexpected processes spawning inside containers (e.g., a shell launched in an app container)
- Network connections to known-malicious IP addresses or domains
- Suspicious file system writes (e.g., writing executables to `/tmp` then running them)
- Container escape attempts (e.g., host namespace access)

**EKS_ADDON_MANAGEMENT** - GuardDuty manages the agent add-on lifecycle automatically. It installs the add-on when the detector is enabled, upgrades it when new versions are released, and removes it if the feature is disabled. This removes the operational overhead of tracking and updating the agent manually.

**Findings** are published to the GuardDuty console and to Amazon EventBridge every six hours by default. From EventBridge they can be routed to SNS for PagerDuty or Slack alerts, or to a Security Hub for centralised finding management.

**Why:**

The Kubernetes API server, container runtime, and Linux kernel are all potential attack surfaces. Static controls (network policies, PSA, seccomp) prevent known-bad configurations but cannot detect zero-day exploits, supply chain compromises, or attacker behaviour that starts from a legitimate pod. GuardDuty provides the detection layer that static controls cannot:

- A compromised dependency that opens a reverse shell is blocked by network policy (no outbound port) but the shell attempt itself is visible to the runtime sensor as an anomalous exec.
- An attacker who obtains valid credentials and calls the Kubernetes API from an unusual region is detected by audit log analysis but would not trigger any static policy.
- A container escape to the host filesystem is visible to the eBPF sensor as a host path access from a container PID namespace.

The guide's primary recommendation for EKS runtime security is GuardDuty because it requires zero manual seccomp profile authoring, zero AppArmor profile management, and no third-party agent to maintain. The eBPF sensor is read-only with minimal CPU/memory overhead and does not intercept the syscall path (no latency impact).


### 2. Seccomp RuntimeDefault Profile (Existing)

**File:** `gitops/apps/aws/staging/acme/values.yaml`

```yaml
podSecurityContext:
  seccompProfile:
    type: RuntimeDefault
```

The Pod Security Admission `restricted` profile (applied to the `acme` namespace) enforces `seccompProfile: RuntimeDefault` as a hard requirement. RuntimeDefault enables the container runtime's built-in syscall allowlist, which blocks approximately 40 dangerous syscalls (including `ptrace`, `mount`, `kexec_load`, `create_module`) that are not needed by any normal application workload.

This is the first layer of runtime defence: GuardDuty detects anomalous behaviour; seccomp prevents the kernel from executing the syscall in the first place.


### 3. Linux Capabilities Dropped (Existing)

**File:** `gitops/apps/aws/staging/acme/values.yaml`

```yaml
securityContext:
  capabilities:
    drop:
      - ALL
  allowPrivilegeEscalation: false
```

All Linux capabilities are dropped from application containers. Capabilities are fine-grained superuser privileges (e.g., `CAP_NET_ADMIN`, `CAP_SYS_PTRACE`, `CAP_SYS_MODULE`). Dropping all of them means the container process cannot:
- Load or unload kernel modules
- Trace other processes
- Reconfigure network interfaces
- Change system time
- Bind to privileged ports directly

PSA `restricted` enforces this at the admission level, so misconfigured workloads that forget to drop capabilities are rejected at deployment time, not just at runtime.


### 4. SELinux via Bottlerocket (Existing)

**File:** `provision/aws/cloudformation/nodegroup.yaml`

```yaml
AmiType: BOTTLEROCKET_x86_64
```

Bottlerocket ships with SELinux in enforcing mode using an Amazon-authored policy. Unlike seccomp (which filters syscalls) and capabilities (which remove superuser powers), SELinux enforces mandatory access control on file system paths, IPC objects, and network sockets. A container process that escapes its namespace restrictions still hits the SELinux policy on the host.

Key protections from Bottlerocket's SELinux policy:
- Container processes are confined to the `container_t` type; host system binaries run as `system_u:system_r:*_t`
- Cross-type access (container writing to host systemd socket, for example) is denied by the policy even if the container has `CAP_DAC_OVERRIDE`
- The OS image itself is read-only and verified by dm-verity on every boot, preventing persistent host-level modifications

SELinux + seccomp + capability dropping provides defence-in-depth where each layer is independent: bypassing one does not bypass the others.


## Future Work

- **GuardDuty finding export to S3:** Add `AWS::GuardDuty::Filter` or configure the detector to export findings to an S3 bucket for long-term retention and SIEM ingestion.
- **EventBridge rule for critical findings:** Add an `AWS::Events::Rule` that routes HIGH severity GuardDuty findings to an SNS topic for immediate alerting.
- **Custom seccomp profiles:** For workloads where RuntimeDefault is too permissive or too restrictive, use the Security Profiles Operator to record the exact syscalls used by a workload and generate a tailored profile.
- **Additional GuardDuty features:** Enable `S3_DATA_EVENTS` and `MALWARE_PROTECTION` features if S3 buckets or EBS volumes hold sensitive data that warrants malware scanning.
