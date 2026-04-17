# Database: CloudNativePG (CNPG)

References:
- [CloudNativePG documentation](https://cloudnative-pg.io/documentation/)
- [Barman Cloud plugin](https://cloudnative-pg.io/plugin-barman-cloud/docs/)
- [AWS EKS Best Practices: Running stateful workloads](https://docs.aws.amazon.com/eks/latest/best-practices/storage.html)


## Overview

Each customer namespace runs an isolated PostgreSQL cluster managed by the CloudNativePG
operator. The operator handles provisioning, configuration, failover, health checks, and
backup coordination. No manual PostgreSQL administration is required.

The reference implementation is in `gitops/apps/aws/staging/acme/`.


## Operator Deployment

**File:** `gitops/infrastructure/controllers/base/cnpg/`

CNPG is deployed as a Flux HelmRelease in the `cnpg-system` namespace. It is a
cluster-scoped operator: one installation manages CNPG Cluster resources across all
customer namespaces.

**Why Flux-managed instead of manual Helm install?**
The operator must be present before any CNPG Cluster resource is applied. Flux manages
this through the reconciliation chain: `infrastructure-controllers` (which includes CNPG)
must be healthy before `apps` (which creates CNPG clusters) is reconciled. Installing
the operator manually before Flux bootstrap creates a duplicate Helm release that conflicts
with Flux's managed release.


## Cluster Configuration

**File:** `gitops/apps/aws/staging/acme/cnpg-cluster.yaml`

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: acme-db
  namespace: acme
spec:
  instances: 1
  storage:
    size: 5Gi
    storageClass: gp3-encrypted
  bootstrap:
    initdb:
      database: n8n
      owner: n8n
      secret:
        name: acme-db-credentials
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: acme-backup-store
```

**Why instances: 1 for staging?**
A single instance is appropriate for staging where HA is not required. For production,
set `instances: 3` with `maxSyncReplicas: 1` to require at least one synchronous replica
before the primary acknowledges a write. CNPG handles primary election and failover
automatically with multiple instances.

**Why gp3-encrypted StorageClass?**
PostgreSQL data and WAL directories are written to an EBS volume. The `gp3-encrypted`
StorageClass provisions gp3 EBS volumes (3,000 IOPS, 125 MiB/s baseline) with
AES-256 encryption. See [Data Encryption](../security/data-encryption.md) for full
rationale.

**Why does CNPG retry until the bootstrap secret exists?**
The bootstrap `secret: name: acme-db-credentials` is created by the Secrets Store CSI
Driver when the n8n pod first mounts its volume. CNPG watches for the secret and retries
until it appears, no explicit ordering or init container is needed. This avoids a
circular dependency between CNPG (needs secret) and n8n (mounts the secret volume).

**Why not store the DB password in a Kubernetes Secret in Git?**
Storing credentials in Git creates a persistent artifact of sensitive data, even with
encryption. The approach here routes credentials through AWS Secrets Manager → CSI Driver
→ synced Kubernetes Secret. The secret only exists in etcd (protected by KMS envelope
encryption) and is never committed to the repository.


## Barman Cloud Plugin

**Why a plugin instead of built-in Barman support?**
CNPG v0.27+ replaced the built-in `barmanObjectStore` backup configuration with a plugin
architecture. The `barman-cloud` plugin handles WAL archiving and base backups as a
sidecar within each CNPG pod. Using the plugin is the current supported approach for
this version of CNPG.

**Installation:** The Barman Cloud plugin is installed via a raw manifest (not Helm)
after Flux bootstrap. It must be installed after Flux because the plugin manifest
includes `Certificate` and `Issuer` resources that require cert-manager CRDs to be
present.

```bash
make install-barman-plugin
```


## Backups

### ObjectStore

**File:** `gitops/apps/aws/staging/acme/objectstore.yaml`

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: acme-backup-store
  namespace: acme
spec:
  configuration:
    destinationPath: s3://${cnpgBackupBucket}/acme
    s3Credentials:
      inheritFromIAMRole: true
  retentionPolicy: "30d"
```

The `ObjectStore` resource defines the backup destination and credentials for the Barman
plugin. `${cnpgBackupBucket}` is substituted by Flux from the `cluster-vars` ConfigMap at
reconcile time (set via `make create-cluster-vars` after `make deploy-s3`).

**Why inheritFromIAMRole?**
`s3Credentials.inheritFromIAMRole: true` tells the Barman plugin to use the AWS
credential provider chain. The CNPG pod's service account is linked to the
`CnpgBackupRole` IAM role via a Pod Identity association. The Pod Identity Agent injects
short-lived STS credentials into the pod at runtime, no static access keys are stored
anywhere.

**What does retentionPolicy: "30d" do?**
After each successful backup, the Barman plugin scans the S3 bucket and deletes backup
data older than 30 days (the Point of Recoverability). This controls how far back in time
a point-in-time restore can target. The S3 lifecycle rule (`ExpireOldBackups: 35 days`)
is a safety net for orphaned objects that Barman fails to clean up.

### Scheduled Backup

**File:** `gitops/apps/aws/staging/acme/scheduled-backup.yaml`

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: acme-db-backup
spec:
  schedule: "0 2 * * *"
  backupOwnerReference: self
  cluster:
    name: acme-db
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

A full base backup runs daily at 02:00 UTC. Between base backups, WAL segments are
continuously archived to S3 by the Barman plugin sidecar. This enables point-in-time
recovery to any second within the retention window.

**Why 02:00 UTC?**
Off-peak hours reduce the impact of backup I/O on active workloads. Adjust the cron
schedule for production based on traffic patterns.

**Why backupOwnerReference: self?**
Sets the `ScheduledBackup` resource as the owner of each `Backup` object it creates.
When the `ScheduledBackup` is deleted, all associated `Backup` objects are garbage
collected automatically.

**Why method: plugin?**
The `plugin` method uses the Barman Cloud plugin sidecar for backups. The alternative
`barmanObjectStore` method (built into earlier CNPG versions) is deprecated. The plugin
method is the correct approach for CNPG versions that ship the plugin architecture.


## Backup Security

**Ransomware and deletion protection:**
The `CnpgBackupRole` only holds `s3:DeleteObject`, not `s3:DeleteObjectVersion`. With
S3 versioning enabled on the backup bucket, `s3:DeleteObject` creates a delete marker
rather than permanently removing an object. A compromised CNPG pod cannot destroy
backups, previous versions remain recoverable for 30 days (matching `retentionPolicy`).

Permanent deletion would require `s3:DeleteObjectVersion`, which is not granted.

See [Data Encryption](../security/data-encryption.md) for bucket versioning and
lifecycle rule details.


## Monitoring CNPG

```bash
# Check cluster status
kubectl get cluster -n acme

# Check backup status
kubectl get backup -n acme

# Check scheduled backup
kubectl get scheduledbackup -n acme

# View CNPG operator logs
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg

# View CNPG cluster events
kubectl describe cluster acme-db -n acme
```

Common status conditions on the Cluster resource:
- `Ready: True`: all instances healthy
- `ContinuousArchiving: True`: WAL archiving to S3 is active
- The `primaryEndpoint` field shows the read-write service hostname


## Restore

To restore to a point in time from S3 backups, create a new Cluster resource with a
`bootstrap.recovery` block instead of `bootstrap.initdb`:

```yaml
bootstrap:
  recovery:
    source: acme-backup-store
    recoveryTarget:
      targetTime: "2026-04-01 03:00:00"
externalClusters:
  - name: acme-backup-store
    barmanObjectStore:
      destinationPath: s3://<bucket>/acme
      s3Credentials:
        inheritFromIAMRole: true
```


## Future Work

- **Production HA:** Set `instances: 3`, `maxSyncReplicas: 1` for synchronous replication.
  CNPG performs automatic failover; promote a replica to primary within seconds of a
  primary failure.
- **ABAC on backup role:** Restrict `CnpgBackupRole` to the customer's own S3 prefix
  using `aws:PrincipalTag/kubernetes-namespace` condition on the IAM policy.
- **Loki dashboard for CNPG logs:** Create a Grafana dashboard that surfaces CNPG log
  patterns (replication lag, checkpoint warnings, connection pool saturation).
