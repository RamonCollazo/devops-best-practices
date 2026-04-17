# Data Encryption and Secrets Management

Reference: [AWS EKS Best Practices: Data Encryption and Secrets Management](https://docs.aws.amazon.com/eks/latest/best-practices/data-encryption-and-secrets-management.html)

---

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
Rotation generates a new cryptographic material version but does not re-encrypt existing
secrets immediately; they are re-encrypted on the next write. All previous key versions
are kept so existing secrets can still be decrypted.

**Why:**
Without `EncryptionConfig`, Kubernetes Secrets in etcd are stored as base64-encoded
plaintext. Anyone with read access to the etcd data volume (e.g. a compromised control
plane node) can decode every secret in the cluster. KMS envelope encryption adds a
mandatory AWS API call to every secret read, ensuring that:

- Stolen etcd snapshots are useless without KMS access
- Secret access is visible in CloudTrail (every KMS Decrypt call is logged)
- Revoking access to the KMS key immediately prevents decryption of all secrets

This is defense-in-depth on top of the Secrets Store CSI Driver approach: application
secrets never enter etcd in the first place, but Kubernetes-internal secrets (service
account tokens, TLS certs created by cert-manager, Flux git credentials) are now also
protected.

---

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
Defines a StorageClass that instructs the EBS CSI driver to create encrypted EBS volumes
for every PersistentVolumeClaim. `encrypted: "true"` without a `kmsKeyId` uses the
account's default EBS encryption key (an AWS-managed CMK). Setting this as the cluster
default (`is-default-class: "true"`) means any PVC that does not explicitly name a
StorageClass gets an encrypted volume automatically.

`WaitForFirstConsumer` defers volume creation until a pod is scheduled, ensuring the
EBS volume is created in the same Availability Zone as the node.

**Why:**
CNPG database pods write customer data to EBS volumes. Without encryption, the raw disk
content is readable by anyone with access to the underlying AWS infrastructure. Encrypted
EBS volumes ensure that data at rest on the PostgreSQL WAL and data directories is
protected even if the physical storage is accessed directly. This also satisfies common
compliance requirements (SOC 2, HIPAA, PCI DSS) that mandate encryption at rest.

Setting this as the default class means future workloads added to the cluster are
encrypted by default without requiring explicit per-PVC configuration.

---

### 3. AWS Secrets Manager via CSI Driver (Existing)

**Files:** `gitops/apps/aws/staging/acme/secretproviderclass.yaml`, `eks.yaml`

Already implemented in the initial build. Customer secrets (`db-user`, `db-password`,
`encryption-key`) are stored in AWS Secrets Manager and mounted into pods as files by the
Secrets Store CSI Driver. They never enter Kubernetes etcd as Kubernetes Secrets (except
as synced copies for CNPG bootstrap, which are now protected by KMS encryption above).

Key properties of this approach:
- No static credentials in Git, ConfigMaps, or container images
- Secrets are rotated in Secrets Manager without redeploying pods (CSI driver polls for changes)
- Access is controlled by IAM via Pod Identity - each customer's pods only access their own secrets
- Every `GetSecretValue` call appears in CloudTrail

---

### 4. Audit Log Coverage for Secret Access

**File:** `provision/aws/cloudformation/eks.yaml` (existing)

```yaml
Logging:
  ClusterLogging:
    EnabledTypes:
      - Type: api
      - Type: audit
```

The `audit` log type captures every Kubernetes API request including `get` on Secret
objects. To surface secret access patterns, run the following CloudWatch Logs Insights
query against the EKS audit log group:

```
fields @timestamp, @message
| filter verb="get" and objectRef.resource="secrets"
| display objectRef.namespace, objectRef.name, user.username, responseStatus.code
| sort @timestamp desc
```

---

## Future Work

- **Customer-managed KMS key for EBS:** Replace the AWS-managed EBS default key with a
  CMK by adding `kmsKeyId: <key-arn>` to the StorageClass parameters. A CMK provides
  CloudTrail visibility on every EBS volume decrypt operation and allows key revocation.
- **Additional control plane logs:** Add `authenticator`, `scheduler`, and
  `controllerManager` log types to the EKS cluster for full visibility.
- **Secret rotation automation:** Configure AWS Secrets Manager rotation Lambda functions
  for automatic credential rotation without manual intervention.
