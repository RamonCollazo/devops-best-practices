# Deploy Guide: AWS Staging

This guide walks through the full deployment from zero to a running cluster. Each step
explains not just what to run but why that step must happen in that order.


## Prerequisites

- AWS CLI configured with credentials for the target account
- `kubectl`, `helm`, `flux` CLI installed
- `GITHUB_TOKEN` environment variable set to a GitHub PAT with `repo` scope (for Flux bootstrap)
- `ADMIN_ROLE_ARN` environment variable set to the IAM role ARN that should receive
  cluster-admin access (e.g. the role assumed by your terminal session)


## Step 1: VPC

```bash
make deploy-vpc
```

Creates the VPC, public/private subnets across 3 AZs, NAT Gateways, and route tables.
All EKS nodes will live in private subnets, no direct internet exposure.

**Why first?** Everything else depends on VPC networking. EKS, the node group, and NAT
Gateways all reference VPC and subnet IDs exported from this stack.


## Step 2: EKS Cluster

```bash
make deploy-eks
```

Creates:
- EKS cluster with KMS envelope encryption for etcd secrets
- OIDC provider (required for EBS CSI IRSA)
- CoreDNS managed add-on
- EBS CSI driver managed add-on (with IRSA role)
- Pod Identity agent managed add-on
- Secrets Store CSI driver managed add-on (`syncSecret.enabled: true`)
- GuardDuty detector with EKS audit log and runtime monitoring
- Admin access entry for `ADMIN_ROLE_ARN`

**Why BootstrapSelfManagedAddons: false?** This prevents EKS from installing `aws-node`
(VPC CNI) and `kube-proxy` as self-managed add-ons. Cilium replaces both. If they were
installed first, there would be a conflict and pods would get duplicate network configs.

**Why before S3?** No dependency, but EKS takes several minutes to provision. Running
deploy-eks first lets it complete in parallel with thinking about the S3 setup.


## Step 3: S3 Backup Bucket

```bash
make deploy-s3
```

Creates the CNPG backup S3 bucket and the `CnpgBackupRole` IAM role for Pod Identity.

**Why before the node group?** The `create-cluster-vars` step (step 7) needs the bucket
name from this stack's output. Running it early avoids blocking later.

**Why not after nodegroup?** No hard dependency, but completing it early means the cluster
vars ConfigMap can be created as soon as Flux is running.


## Step 4: Update kubeconfig

```bash
make kubeconfig
```

Updates `~/.kube/devops-best-practices-staging-aws.yaml` with credentials for the new
cluster. Required before any `kubectl` or `flux` commands.


## Step 5: Add Helm Repositories

```bash
make helm-repos
```

Adds the Cilium, Jetstack (cert-manager), and CNPG Helm repos to the local Helm client.
Required before the manual Cilium install.


## Step 6: Install Gateway API CRDs

```bash
make install-gateway-api-crds
```

Installs the Kubernetes Gateway API Custom Resource Definitions into the cluster.

**Why before Cilium?** Cilium's Helm chart validates the presence of Gateway API CRDs
at install time when `gatewayAPI.enabled: true`. If the CRDs are absent, the Cilium
install fails with a validation error.

**Why not managed by Flux?** Gateway API CRDs must exist before Cilium, which must exist
before Flux. This is part of the bootstrap sequence, Flux cannot manage these CRDs until
it itself is running.


## Step 7: Install Cilium (Bootstrap)

```bash
make install-cilium
```

Installs Cilium manually via Helm with ENI mode, kube-proxy replacement, and Gateway API
enabled.

**Why manual?** Cilium must be running before nodes join. Nodes only become `Ready` when
a CNI plugin is present. Flux runs as pods that need networking, Flux cannot start
without Cilium, and Cilium cannot be managed by Flux until Flux is running. This is the
bootstrap dependency that requires exactly one manual install.

After bootstrap, Flux manages Cilium via HelmRelease and will reconcile any chart
upgrades or value changes automatically.

**Why ENI mode?** See [Cilium documentation](../networking/cilium.md) for full rationale.


## Step 8: Node Group

```bash
make deploy-nodegroup
```

Creates the managed node group: Bottlerocket AMI, m5.xlarge, private subnets, IMDSv2
enforced, encrypted gp3 root volume, Cilium ENI IAM policy on the node role.

**Why after Cilium?** When nodes join the cluster, kubelet immediately tries to configure
pod networking via the CNI plugin. If Cilium is not installed, every node stays in
`NotReady` state indefinitely. Always install Cilium before the node group.


## Step 9: IAM Roles

```bash
make deploy-iam
```

Creates the `SecretsReaderRole` for n8n pods to read from Secrets Manager via Pod
Identity. This role is not cluster-specific and could run in parallel with EKS, but
it references the EKS stack for naming consistency.


## Step 10: Flux Bootstrap

```bash
export GITHUB_TOKEN=<your-pat>
make flux-bootstrap
```

Bootstraps Flux v2 into the cluster. Flux:
1. Installs its own controllers (`flux-system` namespace)
2. Creates a `GitRepository` resource pointing to this repo
3. Applies the cluster entry point (`clusters/aws/staging/`) which creates the
   `infrastructure`, `apps`, and `monitoring` Kustomization resources
4. Begins reconciling: `infrastructure-controllers` → `infrastructure-configs` → `apps`
   and `monitoring-controllers` → `monitoring-configs`

**What Flux deploys automatically:**
- cert-manager (HelmRelease in infrastructure-controllers)
- CNPG operator (HelmRelease in infrastructure-controllers)
- Shared Gateway (infrastructure-configs)
- ClusterIssuer for Let's Encrypt (infrastructure-configs)
- kube-prometheus-stack, Loki, Promtail (monitoring-controllers)
- Grafana Certificate and HTTPRoute (monitoring-configs)

**Why not install cert-manager or CNPG manually?**
Installing them before Flux creates a Helm release that Flux cannot adopt. When Flux
tries to reconcile its own HelmRelease for the same chart, it finds a conflicting release
and enters a failure loop. Let Flux own the full lifecycle from the start.


## Step 11: Cluster Variables ConfigMap

```bash
make create-cluster-vars
```

Creates the `cluster-vars` ConfigMap in the `flux-system` namespace with:
- `k8sServiceHost`: the EKS API server endpoint (used by Cilium's kube-proxy replacement)
- `cnpgBackupBucket`: the S3 bucket name (used by the Barman ObjectStore `destinationPath`)

Flux uses `postBuild.substituteFrom` to inject these values into manifests at reconcile
time. Without this ConfigMap, manifests that contain `${k8sServiceHost}` or
`${cnpgBackupBucket}` cannot be rendered and the reconciliation fails.

**Why after flux-bootstrap?** The ConfigMap must exist in the `flux-system` namespace.
That namespace is created by `flux bootstrap`. Running this step before bootstrap would
require creating the namespace manually.

**Why after deploy-s3?** The bucket name comes from the S3 CloudFormation stack output.
Run `make create-cluster-vars` only after `make deploy-s3` has completed.


## Step 12: Barman Cloud Plugin

```bash
make install-barman-plugin
```

Installs the Barman Cloud plugin for CNPG by applying a raw manifest.

**Why after flux-bootstrap?** The Barman plugin manifest includes `Certificate` and
`Issuer` resources (for its own webhook TLS). These require cert-manager CRDs to be
present. cert-manager is deployed by Flux as part of `infrastructure-controllers`. Running
`install-barman-plugin` before Flux has reconciled cert-manager will fail.

**Why not managed by Flux?** The plugin is installed as a raw manifest (not a Helm
chart), and its versioning lifecycle is separate from the cluster. It could be added to
Flux management in the future, but for now it is installed once as a bootstrap step.


## Step 13: Per-Customer Setup

For each customer namespace:

```bash
# a) Create the three secrets in AWS Secrets Manager:
#    <customer>-n8n-db-user
#    <customer>-n8n-db-password
#    <customer>-n8n-encryption-key

# b) Create Pod Identity associations
make create-pod-identity-association NAMESPACE=<customer>
make create-cnpg-backup-association NAMESPACE=<customer>

# c) Add customer manifests under gitops/apps/aws/staging/<customer>/
#    Use gitops/apps/aws/staging/acme/ as the reference implementation

# d) Commit and push: Flux reconciles automatically

# e) Point DNS: <customer>.<domain> → Gateway ELB hostname
#    Get the ELB hostname:
kubectl get gateway -n shared-gateway shared-gateway \
  -o jsonpath='{.status.addresses[0].value}'
```

**Why create secrets before pushing manifests?**
The SecretProviderClass references Secrets Manager secret names. If the pod starts before
the secrets exist, the CSI driver fails to mount the volume and the pod stays in
`CreateContainerConfigError`. Create secrets first, then push the manifests.

**Why Pod Identity associations before the pod starts?**
Without a PodIdentityAssociation, the pod's service account has no IAM role binding.
Calls to Secrets Manager and S3 return `AccessDenied`. Create the associations before
Flux reconciles the customer namespace.


## Monitoring Deploy Status

```bash
# Overall status
flux get kustomizations

# HelmRelease status
flux get helmreleases -A

# Pod status
kubectl get pods -A

# Force reconcile if something is stuck
flux reconcile source git flux-system
flux reconcile kustomization infrastructure-controllers
```


## Teardown (Reverse Order)

```bash
make delete-apps        # Suspends apps kustomization, deletes CNPG clusters and PVCs
make delete-infra       # Suspends all Flux kustomizations, deletes shared-gateway (removes ELB)
make delete-iam
make delete-s3          # Empty the bucket first if backups exist:
                        # aws s3 rm s3://<bucket> --recursive
make delete-nodegroup
make delete-eks
make delete-vpc
```

**Why delete shared-gateway before EKS?**
Deleting the `shared-gateway` namespace triggers the cloud controller manager to
remove the AWS Load Balancer. If the EKS cluster is deleted first, the ELB becomes
orphaned, it continues to exist and incur charges, and its ENIs may block VPC deletion
(subnets cannot be deleted while ENIs exist in them).

**Why delete-infra before delete-eks?**
Flux kustomizations must be suspended before cluster deletion. If Flux is running and
the cluster starts being torn down, Flux will try to recreate resources that are being
deleted, potentially causing stuck finalizers and blocking the deletion.
