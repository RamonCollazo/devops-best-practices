# AWS EKS Best Practices: Implementation Traceability

This document maps every AWS EKS Best Practices Guide recommendation to the exact file
and configuration in this repository that implements it. Use this as an audit trail to
verify compliance with the guide or to understand why a particular configuration choice
was made.

Source: [AWS EKS Best Practices Guide](https://docs.aws.amazon.com/eks/latest/best-practices/introduction.html)


## Identity and Access Management

Source: [IAM Best Practices](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html)

| Best Practice | Implementation | File |
|---------------|----------------|------|
| **Use Cluster Access Manager (CAM) API instead of aws-auth ConfigMap** | `AuthenticationMode: API` | `provision/aws/cloudformation/eks.yaml` → `EKSCluster.AccessConfig` |
| **Remove cluster-admin permissions from the cluster creator principal** | `BootstrapClusterCreatorAdminPermissions: false` | `provision/aws/cloudformation/eks.yaml` → `EKSCluster.AccessConfig` |
| **Create cluster with a dedicated IAM role** | `ClusterRole` resource with only `AmazonEKSClusterPolicy` | `provision/aws/cloudformation/eks.yaml` → `ClusterRole` |
| **Employ least-privileged access to AWS resources** | `SecretsReaderRole` scoped to `*-n8n-*` secrets only; `CnpgBackupRole` scoped to backup bucket only | `provision/aws/cloudformation/iam.yaml`, `s3.yaml` |
| **Use EKS Pod Identities over IRSA** | Trust policy `Service: pods.eks.amazonaws.com`; `PodIdentityAgentAddon` installed | `provision/aws/cloudformation/eks.yaml` → `PodIdentityAgentAddon`; `iam.yaml`; `s3.yaml` |
| **Use ABAC with EKS Pod Identities** | Pod Identity session tags (`kubernetes-namespace`, `kubernetes-service-account`) are automatically injected: ready for ABAC conditions | `provision/aws/cloudformation/s3.yaml` → `CnpgBackupRole` (future: add `PrincipalTag` condition) |
| **Don't use service account tokens for authentication** | `automountServiceAccountToken: false` on n8n ServiceAccount | `gitops/apps/aws/staging/acme/serviceaccount.yaml` |
| **Update aws-node to use IRSA** | Not applicable: Cilium replaces `aws-node` entirely (`BootstrapSelfManagedAddons: false`) | `provision/aws/cloudformation/eks.yaml` → `EKSCluster.BootstrapSelfManagedAddons` |


## Cluster Access Management

Source: [Cluster Access Management](https://docs.aws.amazon.com/eks/latest/best-practices/cluster-access-management.html)

| Best Practice | Implementation | File |
|---------------|----------------|------|
| **Use IAM Identity Center with CAM API** | `AuthenticationMode: API`; `AdminAccessEntry` resource grants cluster-admin via Access Entry | `provision/aws/cloudformation/eks.yaml` → `AdminAccessEntry` |
| **Benefits over ConfigMap: API-validated, CloudTrail-logged, CloudFormation-managed** | All access management through `AWS::EKS::AccessEntry` CloudFormation resources | `provision/aws/cloudformation/eks.yaml` |
| **EKS Pod Identities for workload IAM** | Both n8n (Secrets Manager) and CNPG (S3) use Pod Identity | `provision/aws/cloudformation/iam.yaml`, `s3.yaml` |


## Pod Security

Source: [Pod Security Best Practices](https://docs.aws.amazon.com/eks/latest/best-practices/pod-security.html)

| Best Practice | Implementation | File |
|---------------|----------------|------|
| **Use multiple PSA modes (enforce + warn + audit) for better user experience** | All three modes set to `restricted` on customer namespaces | `gitops/apps/aws/staging/acme/namespace.yaml` |
| **Use `restricted` Pod Security Standard for production workloads** | `pod-security.kubernetes.io/enforce: restricted` | `gitops/apps/aws/staging/acme/namespace.yaml` |
| **Restrict containers that can run as privileged** | `allowPrivilegeEscalation: false`; `capabilities.drop: [ALL]`; `runAsNonRoot: true` | `gitops/apps/aws/staging/acme/values.yaml` → `securityContext` |
| **Use seccomp RuntimeDefault profile** | `seccompProfile.type: RuntimeDefault`: also required by PSA `restricted` | `gitops/apps/aws/staging/acme/values.yaml` → `podSecurityContext` |
| **Drop Linux capabilities** | `capabilities.drop: [ALL]`: removes every capability; n8n needs none | `gitops/apps/aws/staging/acme/values.yaml` → `securityContext` |
| **Apply PSA to the shared-gateway namespace** | `baseline` enforce (allows cert-manager solver pods); `restricted` warn+audit | `gitops/infrastructure/configs/base/gateway/namespace.yaml` |
| **Use readOnlyRootFilesystem** | `readOnlyRootFilesystem: true`; writable emptyDir volumes for `/tmp` and app data | `gitops/apps/aws/staging/acme/values.yaml` → `securityContext`, `volumes` |


## Network Security

Source: [Network Security Best Practices](https://docs.aws.amazon.com/eks/latest/best-practices/network-security.html)

| Best Practice | Implementation | File |
|---------------|----------------|------|
| **Follow principle of least privilege: create a default deny policy** | `CiliumNetworkPolicy` with empty `endpointSelector: {}` and empty ingress/egress rules | `gitops/apps/aws/staging/acme/netpol-default-deny.yaml` |
| **Create a rule to allow DNS queries** | Explicit egress to CoreDNS (`kube-system/kube-dns`) on UDP+TCP 53 | `gitops/apps/aws/staging/acme/netpol-allow-dns.yaml` |
| **Incrementally add rules to selectively allow traffic between namespaces/pods** | Seven explicit allow policies covering only the exact flows needed | `gitops/apps/aws/staging/acme/netpol-allow-*.yaml` |
| **Monitor network policy enforcement** | Cilium Hubble enabled (`hubble.relay.enabled: true`, `hubble.ui.enabled: true`) for real-time flow visibility | `gitops/infrastructure/controllers/base/cilium/values.yaml` |


## Data Encryption and Secrets Management

Source: [Data Encryption and Secrets Management](https://docs.aws.amazon.com/eks/latest/best-practices/data-encryption-and-secrets-management.html)

| Best Practice | Implementation | File |
|---------------|----------------|------|
| **Use AWS KMS for envelope encryption of Kubernetes secrets** | `EncryptionConfig` with dedicated CMK (`EtcdEncryptionKey`) applied to `secrets` resource type | `provision/aws/cloudformation/eks.yaml` → `EKSCluster.EncryptionConfig` |
| **Rotate your CMKs periodically** | `EnableKeyRotation: true`: annual automatic rotation | `provision/aws/cloudformation/eks.yaml` → `EtcdEncryptionKey` |
| **Use an external secrets provider** | Secrets Store CSI Driver (EKS managed add-on) + AWS Secrets Manager | `provision/aws/cloudformation/eks.yaml` → `CsiSecretsStoreAddon`; `gitops/apps/aws/staging/acme/secretproviderclass.yaml` |
| **Use volume mounts instead of environment variables** | Secrets are mounted as files via CSI volume; only the encryption key is exposed as an env var (required by n8n) | `gitops/apps/aws/staging/acme/values.yaml` → `volumes`, `volumeMounts` |
| **Audit the use of Kubernetes Secrets** | `api` and `audit` log types enabled; every Secret `get` is recorded in the EKS audit log | `provision/aws/cloudformation/eks.yaml` → `EKSCluster.Logging` |
| **Use separate namespaces to isolate secrets from different applications** | Per-customer namespace isolation; each customer's secrets are in their own namespace and Secrets Manager scope | `gitops/apps/aws/staging/acme/namespace.yaml`; `provision/aws/cloudformation/iam.yaml` |
| **Encrypt data at rest (EBS volumes)** | `gp3-encrypted` StorageClass with `encrypted: "true"` as cluster default | `gitops/infrastructure/configs/base/storageclass/storageclass.yaml` |
| **Encrypt S3 backup objects at rest** | `SSEAlgorithm: AES256` on the CNPG backup bucket | `provision/aws/cloudformation/s3.yaml` → `CnpgBackupBucket.BucketEncryption` |


## Runtime Security

Source: [Runtime Security Best Practices](https://docs.aws.amazon.com/eks/latest/best-practices/runtime-security.html)

| Best Practice | Implementation | File |
|---------------|----------------|------|
| **Use Amazon GuardDuty for runtime monitoring** | `GuardDutyDetector` with `EKS_AUDIT_LOGS` and `EKS_RUNTIME_MONITORING` enabled | `provision/aws/cloudformation/eks.yaml` → `GuardDutyDetector` |
| **Use GuardDuty EKS_ADDON_MANAGEMENT for automatic agent lifecycle** | `EKS_ADDON_MANAGEMENT: ENABLED`: GuardDuty installs and upgrades the eBPF agent as an EKS add-on | `provision/aws/cloudformation/eks.yaml` → `GuardDutyDetector.Features` |
| **Drop Linux capabilities before writing seccomp policies** | `capabilities.drop: [ALL]` applied; `seccompProfile: RuntimeDefault` provides syscall filtering | `gitops/apps/aws/staging/acme/values.yaml` → `securityContext`, `podSecurityContext` |
| **Use AppArmor/SELinux** | Bottlerocket enforces SELinux in enforcing mode by default (no additional configuration needed) | `provision/aws/cloudformation/nodegroup.yaml` → `NodeGroup.AmiType: BOTTLEROCKET_x86_64` |
| **Use seccomp** | `seccompProfile.type: RuntimeDefault`: PSA `restricted` enforces this at admission time | `gitops/apps/aws/staging/acme/values.yaml` → `podSecurityContext` |


## Protecting the Infrastructure

Source: [Protecting the Infrastructure](https://docs.aws.amazon.com/eks/latest/best-practices/protecting-the-infrastructure.html)

| Best Practice | Implementation | File |
|---------------|----------------|------|
| **Use an OS optimized for running containers** | `AmiType: BOTTLEROCKET_x86_64`: immutable OS, SELinux enforcing, verified boot, no shell/package manager | `provision/aws/cloudformation/nodegroup.yaml` → `NodeGroup.AmiType` |
| **Keep worker node OS updated** | Managed node group rolling replacement (`MaxUnavailable: 1`): nodes are replaced, not upgraded in place | `provision/aws/cloudformation/nodegroup.yaml` → `NodeGroup.UpdateConfig` |
| **Treat infrastructure as immutable** | Bottlerocket has a read-only OS partition; node updates replace instances rather than modifying them | `provision/aws/cloudformation/nodegroup.yaml` → `AmiType`, `UpdateConfig` |
| **Minimize access to worker nodes** | `AmazonSSMManagedInstanceCore` on node role: SSM Session Manager access only, no SSH, no open ports | `provision/aws/cloudformation/nodegroup.yaml` → `NodeRole.ManagedPolicyArns` |
| **Deploy workers onto private subnets** | Node group placed in private subnets only; only NAT Gateway outbound access | `provision/aws/cloudformation/nodegroup.yaml` → `NodeGroup.Subnets` |
| **Run SELinux** | Bottlerocket ships with SELinux in enforcing mode using an Amazon-authored policy | `provision/aws/cloudformation/nodegroup.yaml` → `AmiType: BOTTLEROCKET_x86_64` |


## Auditing and Logging

Source: [Auditing and Logging](https://docs.aws.amazon.com/eks/latest/best-practices/auditing-and-logging.html)

| Best Practice | Implementation | File |
|---------------|----------------|------|
| **Enable audit logs** | All five control plane log types enabled: `api`, `audit`, `authenticator`, `controllerManager`, `scheduler` | `provision/aws/cloudformation/eks.yaml` → `EKSCluster.Logging` |
| **Utilize audit metadata** | `authenticator` log type surfaces IAM-based authentication attempts; `api` log captures all API server requests | `provision/aws/cloudformation/eks.yaml` → `EKSCluster.Logging` |
| **Audit CloudTrail logs** | All Pod Identity credential exchanges, KMS decrypt calls, and S3 backup operations appear in CloudTrail: no additional configuration required | Architecture-level: IAM + KMS + S3 all emit CloudTrail events |
| **Analyze logs with Log Insights** | EKS audit logs are delivered to CloudWatch Logs; queryable with CloudWatch Logs Insights | `provision/aws/cloudformation/eks.yaml` → `EKSCluster.Logging` |


## Not Yet Implemented

The following best practices from the guide are noted but not yet implemented:

| Best Practice | Source Page | Notes |
|---------------|-------------|-------|
| Run kube-bench for CIS benchmark compliance | [Protecting the Infrastructure](https://docs.aws.amazon.com/eks/latest/best-practices/protecting-the-infrastructure.html) | Post-deploy audit step, not a static config |
| Amazon Inspector for host vulnerability scanning | [Protecting the Infrastructure](https://docs.aws.amazon.com/eks/latest/best-practices/protecting-the-infrastructure.html) | Account-level toggle; SSM agent available via Bottlerocket |
| GuardDuty findings export to S3 / EventBridge alerting | [Runtime Security](https://docs.aws.amazon.com/eks/latest/best-practices/runtime-security.html) | Add `AWS::Events::Rule` + SNS for HIGH severity findings |
| Network policies on infrastructure namespaces | [Network Security](https://docs.aws.amazon.com/eks/latest/best-practices/network-security.html) | `cert-manager`, `cnpg-system`, `flux-system` currently unrestricted |
| FQDN egress policies (Cilium toFQDNs) | [Network Security](https://docs.aws.amazon.com/eks/latest/best-practices/network-security.html) | Replace open port-443 egress with specific hostname allowlists |
| Remove unauthenticated group from system:discovery | [IAM](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html) | Reduces credential-free cluster enumeration surface |
| Custom seccomp profiles | [Runtime Security](https://docs.aws.amazon.com/eks/latest/best-practices/runtime-security.html) | Security Profiles Operator for workload-specific syscall lists |
| ABAC condition on S3 backup policy | [IAM](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html) | `aws:PrincipalTag/kubernetes-namespace` to restrict per-customer S3 prefix |
| Customer-managed KMS key for EBS | [Data Encryption](https://docs.aws.amazon.com/eks/latest/best-practices/data-encryption-and-secrets-management.html) | Add `kmsKeyId` to StorageClass for full CloudTrail on EBS decrypts |
| Secret rotation automation | [Data Encryption](https://docs.aws.amazon.com/eks/latest/best-practices/data-encryption-and-secrets-management.html) | Secrets Manager rotation Lambda for automatic credential rotation |
