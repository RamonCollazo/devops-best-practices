# Data Encryption and Secrets Management

Reference: [AWS EKS Best Practices: Data Encryption and Secrets Management](https://docs.aws.amazon.com/eks/latest/best-practices/data-encryption-and-secrets-management.html)

See [best-practices-traceability.md](best-practices-traceability.md) for a table mapping every best practice to the exact file and config.


## Implemented Practices

### 1. KMS Envelope Encryption for Kubernetes Secrets (etcd)

**File:** `provision/aws/cloudformation/eks.yaml`

```yaml
EtcdEncryptionKey:
  Type: AWS::KMS::Key
  Properties:
    EnableKeyRotation: true

EncryptionConfig:
  - Provider:
      KeyArn: !GetAtt EtcdEncryptionKey.Arn
    Resources:
      - secrets
```

**What it does:**
Every Kubernetes Secret object written to etcd is encrypted using envelope encryption.
EKS generates a unique data encryption key (DEK) per secret, encrypts the DEK with the
CMK, and stores the encrypted DEK alongside the ciphertext in etcd. Decryption requires
a call to KMS; the plaintext key is never stored at rest.

`EnableKeyRotation: true` configures KMS to automatically rotate the CMK annually.
Rotation generates new cryptographic material but does not immediately re-encrypt existing
secrets; they are re-encrypted on next write. All previous key versions are retained so
existing secrets remain decryptable.

**Why:**
Without `EncryptionConfig`, Kubernetes Secrets in etcd are stored as base64-encoded
plaintext. Anyone with read access to the etcd data volume (e.g. a compromised control
plane node) can decode every secret in the cluster. KMS envelope encryption ensures:

- Stolen etcd snapshots are useless without KMS access
- Every secret read appears in CloudTrail as a KMS `Decrypt` call
- Revoking the KMS key immediately prevents decryption of all secrets

This is defense-in-depth on top of the Secrets Store CSI Driver approach. Application
secrets never enter etcd in the first place, but Kubernetes-internal secrets (service
account tokens, TLS certs from cert-manager, Flux git credentials) are protected here.

**Why a CMK instead of AWS-managed key?**
The cluster uses a customer-managed KMS key (CMK) rather than the default AWS-managed EKS
encryption key. A CMK provides:
- Full CloudTrail visibility on every `Decrypt` call (AWS-managed keys log differently)
- The ability to revoke access by disabling the key
- A consistent key alias that can be referenced across stacks


### 2. Encrypted EBS StorageClass as Cluster Default

**File:** `gitops/infrastructure/configs/base/storageclass/storageclass.yaml`

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-encrypted
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

**What it does:**
Defines a StorageClass named `gp3-encrypted` that instructs the EBS CSI driver to
provision encrypted gp3 EBS volumes for every PersistentVolumeClaim. Setting it as the
cluster default (`is-default-class: "true"`) means any PVC without an explicit
`storageClassName` gets an encrypted volume automatically.

**Why gp3 instead of gp2?**
gp3 is the current-generation AWS general-purpose SSD volume type. It provides 3,000 IOPS
and 125 MiB/s throughput at baseline with no extra cost compared to gp2 at equivalent
capacity. gp3 separates IOPS and throughput from capacity, they can be scaled
independently without provisioning more disk. The IOPS and throughput are explicitly set
in the StorageClass so the values are visible and intentional rather than relying on
AWS defaults.

**Why encrypted: "true" without a kmsKeyId?**
Using `encrypted: "true"` without specifying `kmsKeyId` uses the account's default EBS
encryption key. For a production environment, adding `kmsKeyId: <cmk-arn>` provides full
CloudTrail visibility on every EBS decrypt operation and enables key revocation.

**Why WaitForFirstConsumer?**
This binding mode defers EBS volume creation until a pod is scheduled to a specific node.
EBS volumes are Availability Zone-specific, if the volume is created before the pod is
scheduled, it may end up in a different AZ than the node, causing the mount to fail.
`WaitForFirstConsumer` eliminates this race condition entirely.

**Why encryption at rest for database volumes?**
CNPG database pods write customer data, workflow definitions, execution history,
credentials, to EBS volumes. Without encryption, the raw disk content is readable by
anyone with access to the underlying AWS infrastructure (AWS staff with physical access,
or a compromised account). Encrypted EBS ensures data at rest on PostgreSQL data and WAL
directories is protected even if the physical storage is accessed directly. This satisfies
common compliance requirements (SOC 2, HIPAA, PCI DSS).


### 3. AWS Secrets Manager via Secrets Store CSI Driver

**Files:** `gitops/apps/aws/staging/acme/secretproviderclass.yaml`, `provision/aws/cloudformation/eks.yaml`

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: acme-secrets
  namespace: acme
spec:
  provider: aws
  parameters:
    usePodIdentity: "true"
    objects: |
      - objectName: "acme-n8n-db-user"
        objectType: secretsmanager
      - objectName: "acme-n8n-db-password"
        objectType: secretsmanager
      - objectName: "acme-n8n-encryption-key"
        objectType: secretsmanager
  secretObjects:
    - secretName: acme-db-credentials
      type: kubernetes.io/basic-auth
      ...
```

**What it does:**
The Secrets Store CSI Driver (installed as an EKS managed add-on) mounts secrets from
AWS Secrets Manager directly into pods as files at runtime. The `secretObjects` block
additionally syncs the mounted secrets as Kubernetes Secret objects in etcd, these are
required because CNPG reads bootstrap credentials from a Kubernetes Secret, not a mounted
file.

The sync is triggered by the CSI volume mount: when the n8n pod starts and mounts the
`secrets-store` volume, the CSI driver calls Secrets Manager, writes the files, and
creates the Kubernetes Secret objects. CNPG polls for the secret and bootstraps once it
exists.

**Why Secrets Manager over Kubernetes Secrets in Git?**
Storing secrets in Git (even encrypted with SOPS or Sealed Secrets) creates a long-lived
artifact of sensitive data. Secrets Manager provides:
- Centralized audit log of every `GetSecretValue` call (CloudTrail)
- Per-secret IAM access control (only pods with the right Pod Identity can read)
- Secret rotation without redeploying the application
- Immediate revocation by disabling the secret

**Why usePodIdentity instead of IRSA?**
`usePodIdentity: "true"` instructs the CSI driver to obtain AWS credentials from the Pod
Identity Agent rather than reading the service account's projected OIDC token (IRSA). Pod
Identity is the current AWS recommendation and requires no annotation on the
ServiceAccount. See [IAM documentation](iam.md) for the full comparison.

**Why three separate Kubernetes Secret objects?**
The three synced Kubernetes Secrets (`acme-db-credentials`, `acme-n8n-db`,
`acme-n8n-secrets`) each serve a different consumer with different expected key names:

- `acme-db-credentials` (`kubernetes.io/basic-auth` type, keys `username`/`password`) is
  consumed by CNPG's bootstrap `secret` field, which expects this exact type and keys.
- `acme-n8n-db` (Opaque, key `postgres-password`) is consumed by the n8n Helm chart's
  `externalPostgresql.existingSecret` field. The chart always looks for the key
  `postgres-password` regardless of whether the bundled PostgreSQL is enabled.
- `acme-n8n-secrets` (Opaque, key `N8N_ENCRYPTION_KEY`) is consumed via `envFrom` on the
  n8n container. The key name becomes the environment variable name directly.


### 4. S3 Backup Bucket Encryption

**File:** `provision/aws/cloudformation/s3.yaml`

```yaml
BucketEncryption:
  ServerSideEncryptionConfiguration:
    - ServerSideEncryptionByDefault:
        SSEAlgorithm: AES256
```

**What it does:**
Enables S3 server-side encryption with AES-256 (SSE-S3) on the CNPG backup bucket.
Every object written to the bucket is encrypted at rest using AWS-managed keys.

**Why SSE-S3 instead of SSE-KMS?**
SSE-S3 is the simpler choice for this use case. SSE-KMS provides per-request CloudTrail
visibility and key revocation, but adds latency and KMS API costs for every object write.
For backups that are written frequently (WAL segments every few seconds), SSE-S3 is the
appropriate trade-off. The bucket is private (`PublicAccessBlockConfiguration: true` on
all four settings) and access is governed by IAM through Pod Identity.

**Why versioning?**
Versioning protects against two threat scenarios:
1. **Accidental deletion**: if a Barman operation deletes an object by mistake, the previous
   version is immediately recoverable.
2. **Compromised role**: the `CnpgBackupRole` only holds `s3:DeleteObject`, not
   `s3:DeleteObjectVersion`. With versioning enabled, `s3:DeleteObject` creates a delete
   marker rather than permanently removing the object. A compromised role cannot destroy
   backups, it can only mark them deleted, and the previous versions remain intact.

**What are the lifecycle rules?**
Three rules work together to bound storage cost:
- `ExpireNonCurrentVersions` (30 days): permanently removes old versions after 30 days.
  This matches the Barman `retentionPolicy: "30d"` on the ObjectStore, the full backup
  recovery window is always recoverable after an accidental or malicious deletion.
- `ExpireOldBackups` (35 days): hard-expires all objects. Barman's retention cleanup runs
  after each successful backup; this rule is a safety net for orphaned objects (e.g. from
  a failed Barman run) to prevent unbounded bucket growth. The 5-day buffer ensures Barman
  always has a chance to clean up before S3 expires objects.
- `AbortIncompleteMultipartUploads` (1 day): WAL segments are large and uploaded in parts.
  Failed uploads leave orphaned parts that incur storage charges. This rule removes them
  after 24 hours.


### 5. Control Plane Audit Logging

**File:** `provision/aws/cloudformation/eks.yaml`

```yaml
Logging:
  ClusterLogging:
    EnabledTypes:
      - Type: api
      - Type: audit
      - Type: authenticator
      - Type: controllerManager
      - Type: scheduler
```

All five EKS control plane log types are enabled. This surfaces secret access patterns
in CloudWatch Logs. To query secret reads:

```
fields @timestamp, @message
| filter verb="get" and objectRef.resource="secrets"
| display objectRef.namespace, objectRef.name, user.username, responseStatus.code
| sort @timestamp desc
```

See [Infrastructure Security](infrastructure.md) for the rationale on each log type.


## Future Work

- **Customer-managed KMS key for EBS:** Add `kmsKeyId: <key-arn>` to the StorageClass
  parameters to use a CMK instead of the AWS-managed EBS default key. A CMK provides
  CloudTrail visibility on every EBS volume decrypt operation and allows key revocation.
- **SSE-KMS for S3:** If compliance requirements demand per-request S3 decrypt audit logs,
  replace `SSEAlgorithm: AES256` with `SSEAlgorithm: aws:kms` and a dedicated CMK.
- **Secret rotation automation:** Configure Secrets Manager rotation Lambda functions for
  automatic credential rotation without manual intervention.
