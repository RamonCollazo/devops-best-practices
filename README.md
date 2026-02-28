# devops-best-practices

Production-grade Kubernetes platform across AWS, GCP, and Azure.

## Status

| Cloud | Tool | Status |
|-------|------|--------|
| AWS | CloudFormation + EKS | In progress |
| GCP | Terraform + GKE | Planned |
| Azure | ARM + AKS | Planned |

---

## AWS — EKS

### Prerequisites

- AWS CLI configured with sufficient permissions
- `kubectl`
- `helm`

### Infrastructure

CloudFormation stacks under `provision/aws/cloudformation/`:

| Template | What it creates |
|----------|----------------|
| `vpc.yaml` | VPC, public/private subnets across 3 AZs, NAT Gateways, route tables |
| `eks.yaml` | EKS cluster, cluster IAM role, OIDC provider |
| `nodegroup.yaml` | Managed node group, node IAM role, Cilium ENI inline policy |
| `iam.yaml` | IRSA roles for pods (SecretsReaderRole → Secrets Manager, assumed by n8n SA) |

### Deploy order

```bash
# 1. VPC
make deploy-vpc

# 2. EKS cluster
make deploy-eks

# 3. Update kubeconfig
make kubeconfig

# 4. Add Helm repos
make helm-repos

# 5. Install Cilium — must happen before nodes join
make install-cilium

# 6. Node group — nodes join and get networking from Cilium
make deploy-nodegroup

# 7. IRSA roles (needs OIDC provider from step 2)
make deploy-iam

# 8. Install remaining controllers
make install-cert-manager
make install-cnpg
# CSI driver is installed as an EKS add-on (part of deploy-eks, step 2)
```

> **Note:** Cilium must be running before nodes join the cluster. If nodes join
> without a CNI they will sit in `NotReady` indefinitely. Always run
> `install-cilium` before `deploy-nodegroup`.

### Override defaults

```bash
make deploy-all ENVIRONMENT=production REGION=us-west-2
```

| Variable | Default | Description |
|----------|---------|-------------|
| `PROJECT_NAME` | `devops-best-practice-staging` | Used in all resource names |
| `ENVIRONMENT` | `staging` | `staging` or `production` |
| `REGION` | `us-east-1` | AWS region |

### Teardown (reverse order)

```bash
make delete-nodegroup
make delete-eks
make delete-vpc
```

---

## K8s Infrastructure

Helm values under `provision/aws/helm/`:

| Values file | Chart | Namespace |
|-------------|-------|-----------|
| `cilium-values.yaml` | `cilium/cilium` | `kube-system` |
| `cert-manager-values.yaml` | `jetstack/cert-manager` | `cert-manager` |
| `cnpg-values.yaml` | `cnpg/cloudnative-pg` | `cnpg-system` |

The CSI driver and AWS provider are installed as an EKS managed add-on (`aws-secrets-store-csi-driver-provider`) in `eks.yaml` — no Helm values file needed.

**Cilium** runs in ENI mode — pods get real VPC IPs, kube-proxy is replaced by eBPF, Gateway API is enabled for ingress.

**cert-manager** manages TLS certificates. `ClusterIssuers` (Let's Encrypt) are configured in Phase 4.

**Secrets Store CSI Driver** mounts secrets from AWS Secrets Manager directly into pods as files. `secretObjects` creates Kubernetes Secrets for workloads that require them (CNPG bootstrap). No secrets are stored permanently in etcd.

**CloudNativePG** is the PostgreSQL operator. Database clusters are defined in Phase 7.

---

## GitOps

Flux v2 manages all Kubernetes state. The reconciliation chain is:

```
infrastructure-controllers  (Cilium, cert-manager, CNPG)
        ↓
infrastructure-configs       (ClusterIssuers, SecretProviderClasses — Phase 4)
```

Cluster entrypoints live in `clusters/aws/staging/`. GitOps manifests live in `gitops/`.

### Bootstrap

```bash
# Bootstrap Flux (requires GITHUB_TOKEN exported)
# This creates the flux-system namespace and installs all Flux controllers.
export GITHUB_TOKEN=<your-pat>
make flux-bootstrap

# Create cluster-vars ConfigMap (required for Cilium k8sServiceHost substitution)
# Must run after flux-bootstrap so the flux-system namespace exists.
make create-cluster-vars
```

### Monitor reconciliation

```bash
flux get kustomizations
flux get helmreleases -A
```

---

## Roadmap

- [x] EKS provisioning (VPC, EKS, node group)
- [x] K8s infrastructure (Cilium, cert-manager, CNPG, CSI driver via EKS add-on)
- [x] GitOps (Flux v2)
- [ ] CNPG backup (Barman Cloud → S3)
- [ ] EKS hardening
- [ ] Monitoring (kube-prometheus-stack + Loki)
- [ ] Customer onboarding (multi-tenant n8n)
- [ ] GCP (Terraform + GKE)
- [ ] Azure (ARM + AKS)
