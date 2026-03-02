# devops-best-practices

Production-grade multi-tenant Kubernetes platform across AWS, GCP, and Azure.
Reference implementation for a consistent GitOps-driven stack: CNI, TLS, database, backups, and secrets.

## Status

| Cloud | Provisioning | Status |
|-------|-------------|--------|
| AWS | CloudFormation + EKS | In progress |
| GCP | Terraform + GKE | Planned |
| Azure | ARM + AKS | Planned |

---

## Architecture — AWS

### Technology stack

| Layer | Tool |
|-------|------|
| CNI | Cilium (ENI mode, kube-proxy replacement, Gateway API) |
| GitOps | Flux v2 |
| Secrets | Secrets Store CSI Driver (EKS managed add-on) + EKS Pod Identity |
| Ingress | Kubernetes Gateway API — shared Gateway in `shared-gateway` namespace |
| TLS | cert-manager + Let's Encrypt (HTTP01 via GatewayHTTPRoute) |
| Database | CloudNativePG (CNPG) |
| DB Backups | Barman Cloud plugin → S3 (per environment) |
| App workload | n8n (one instance per customer namespace) |
| Monitoring | kube-prometheus-stack + Loki *(planned)* |

### CloudFormation stacks

Templates live under `provision/aws/cloudformation/`:

| Template | What it creates |
|----------|----------------|
| `vpc.yaml` | VPC, public/private subnets across 3 AZs, NAT Gateways, route tables |
| `eks.yaml` | EKS cluster, cluster IAM role, OIDC provider, EBS CSI driver (IRSA + add-on), Pod Identity agent add-on, Secrets Store CSI add-on |
| `nodegroup.yaml` | Managed node group (AL2023, m5.xlarge, private subnets), node IAM role, Cilium ENI inline policy |
| `iam.yaml` | `SecretsReaderRole` — Pod Identity role for n8n pods to read from Secrets Manager |
| `s3.yaml` | Per-environment backup bucket + `CnpgBackupRole` — Pod Identity role for CNPG pods to write backups |

> **Pod Identity** is used instead of IRSA for all app-level roles. No SA annotations required.
> PodIdentityAssociations are created imperatively per customer via Makefile targets.

---

## AWS Deploy Order

```bash
# 1. VPC
make deploy-vpc

# 2. EKS cluster + EBS CSI driver + Pod Identity agent + Secrets Store CSI (EKS add-ons)
make deploy-eks

# 3. S3 backup bucket + CnpgBackupRole
make deploy-s3

# 4. Update kubeconfig
make kubeconfig

# 5. Add Helm repos
make helm-repos

# 6. Gateway API CRDs — must run before Cilium
make install-gateway-api-crds

# 7. Install Cilium — must run before nodes join
make install-cilium

# 8. Node group — nodes join and get networking from Cilium
make deploy-nodegroup

# 9. IAM roles (SecretsReaderRole)
make deploy-iam

# 10. Controllers
make install-cert-manager
make install-cnpg
make install-barman-plugin

# 11. Bootstrap Flux (requires GITHUB_TOKEN)
export GITHUB_TOKEN=<your-pat>
make flux-bootstrap

# 12. Cluster-wide ConfigMap for Flux variable substitution
#     Run after deploy-s3 so cnpgBackupBucket is available
make create-cluster-vars

# 13. Per-customer setup (repeat for each customer)
# a) Create secrets in AWS Secrets Manager:
#      <customer>-n8n-db-user
#      <customer>-n8n-db-password
#      <customer>-n8n-encryption-key
# b) Create Pod Identity associations
make create-pod-identity-association NAMESPACE=<customer>
make create-cnpg-backup-association NAMESPACE=<customer>
# c) Add customer manifests under gitops/apps/aws/staging/<customer>/
# d) Point DNS: <customer>.<domain> → Gateway LoadBalancer hostname
```

> **Note:** Cilium must be running before nodes join. If nodes join without a CNI they sit
> in `NotReady` indefinitely. Always run `install-cilium` before `deploy-nodegroup`.

> **Note:** Do not run `make install-cert-manager` after `flux-bootstrap`. Flux owns
> cert-manager from that point — running it again creates a conflicting Helm release.

### Makefile variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PROJECT_NAME` | `devops-best-practice` | Used in all resource and stack names |
| `ENVIRONMENT` | `staging` | `staging` or `production` |
| `REGION` | `us-east-1` | AWS region |
| `GATEWAY_API_VERSION` | `v1.2.1` | Gateway API CRD version |
| `BARMAN_PLUGIN_VERSION` | `v0.11.0` | Barman Cloud plugin version |

```bash
make deploy-vpc ENVIRONMENT=production REGION=us-west-2
```

### Teardown (reverse order)

```bash
make delete-apps        # removes CNPG clusters so EBS volumes are released
make delete-iam
make delete-s3
make delete-nodegroup
make delete-eks
make delete-vpc
```

---

## K8s Infrastructure

Managed by Flux from `gitops/infrastructure/`.

### Controllers (`infrastructure-controllers`)

| Chart | Namespace | Notes |
|-------|-----------|-------|
| `cilium/cilium` v1.19.1 | `kube-system` | ENI mode, kube-proxy replacement, Gateway API enabled |
| `jetstack/cert-manager` v1.19.4 | `cert-manager` | `--enable-gateway-api` flag, Flux-managed only |
| `cnpg/cloudnative-pg` v0.27.1 | `cnpg-system` | PostgreSQL operator |

CSI driver and AWS provider are EKS managed add-ons — no Helm chart needed.
Barman Cloud plugin is installed via `make install-barman-plugin` (raw manifest, no Helm).

### Configs (`infrastructure-configs`)

| Resource | Namespace | What it does |
|----------|-----------|-------------|
| `Gateway` | `shared-gateway` | Shared Cilium Gateway, HTTP (80) + HTTPS (443) listeners, namespace selector |
| `ClusterIssuer` | cluster-scoped | Let's Encrypt via HTTP01 over GatewayHTTPRoute |

**Cilium** runs in ENI mode — pods get real VPC IPs. `aws-node` and `kube-proxy` DaemonSets are deleted on install.

**cert-manager** issues TLS certs via Let's Encrypt HTTP01. The solver HTTPRoute is created in `shared-gateway` namespace, which must carry label `shared-gateway: "true"` to attach to the Gateway.

**Secrets Store CSI Driver** mounts secrets from AWS Secrets Manager as files and syncs them as Kubernetes Secrets. No static credentials are stored in etcd — Pod Identity injects short-lived AWS credentials at runtime.

**CloudNativePG** manages PostgreSQL clusters. WAL archiving and base backups are handled by the Barman Cloud plugin, writing to S3 with Pod Identity credentials.

---

## GitOps Structure

```
clusters/aws/staging/
  infrastructure.yaml   # infrastructure-controllers → infrastructure-configs
  apps.yaml             # apps (depends on infrastructure-configs)

gitops/
  infrastructure/
    controllers/        # HelmReleases: Cilium, cert-manager, CNPG
    configs/
      base/             # Gateway, ClusterIssuer
      aws/staging/      # Kustomize overlay
  apps/
    aws/staging/
      <customer>/       # Per-customer manifests (one directory per customer)
```

### Flux reconciliation chain

```
infrastructure-controllers  →  infrastructure-configs  →  apps
```

All Kustomizations use `wait: true` — the chain only advances when the previous layer is healthy.

### Bootstrap

```bash
export GITHUB_TOKEN=<your-pat>
make flux-bootstrap

# Creates cluster-vars ConfigMap (k8sServiceHost + cnpgBackupBucket)
# Must run after flux-bootstrap AND after deploy-s3
make create-cluster-vars
```

### Monitor

```bash
flux get kustomizations
flux get helmreleases -A
kubectl get pods -A
```

---

## App Stack — per customer

Each customer gets an isolated namespace with a dedicated n8n instance and CNPG database.
`gitops/apps/aws/staging/acme/` is the reference implementation.

| Manifest | What it creates |
|----------|----------------|
| `namespace.yaml` | Customer namespace with `shared-gateway: "true"` label |
| `serviceaccount.yaml` | n8n SA (no annotation — Pod Identity injects credentials) |
| `secretproviderclass.yaml` | CSI SecretProviderClass — pulls 3 secrets from Secrets Manager into K8s Secrets |
| `objectstore.yaml` | Barman `ObjectStore` — S3 backup destination, credentials via Pod Identity |
| `cnpg-cluster.yaml` | CNPG Cluster — bootstraps from CSI secret, Barman plugin enabled |
| `scheduled-backup.yaml` | Daily backup at 02:00 UTC via Barman plugin |
| `certificate.yaml` | TLS cert (Let's Encrypt) issued in `shared-gateway` namespace |
| `helmrepository.yaml` | community-charts Helm repo |
| `helmrelease.yaml` | n8n Helm release (v1.16.29), values from ConfigMap |
| `httproute.yaml` | HTTPRoute — HTTPS listener, routes to n8n port 5678 |

### Required Secrets Manager secrets

| Secret name | Used by |
|-------------|---------|
| `<customer>-n8n-db-user` | CNPG bootstrap (DB owner username) |
| `<customer>-n8n-db-password` | CNPG bootstrap (password) + n8n DB connection |
| `<customer>-n8n-encryption-key` | n8n `N8N_ENCRYPTION_KEY` env var |

---

## Roadmap

- [x] EKS provisioning (VPC, EKS, node group, IAM, S3)
- [x] K8s infrastructure (Cilium, cert-manager, CNPG, CSI driver, Gateway API)
- [x] GitOps (Flux v2)
- [x] App stack (acme: CNPG + n8n + HTTPRoute + TLS)
- [x] CNPG backups (Barman Cloud plugin → S3, restore tested)
- [ ] EKS hardening
- [ ] Monitoring (kube-prometheus-stack + Loki)
- [ ] Customer onboarding automation (sync-customers.sh)
- [ ] GCP (Terraform + GKE)
- [ ] Azure (ARM + AKS)
