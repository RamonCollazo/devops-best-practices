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
| `nodegroup.yaml` | Managed node group, node IAM role |

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

# 7. Install remaining controllers
make install-cert-manager
make install-external-secrets
make install-cnpg
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
| `external-secrets-values.yaml` | `external-secrets/external-secrets` | `external-secrets` |
| `cnpg-values.yaml` | `cnpg/cloudnative-pg` | `cnpg-system` |

**Cilium** runs in ENI mode — pods get real VPC IPs, kube-proxy is replaced by eBPF, Gateway API is enabled for ingress.

**cert-manager** manages TLS certificates. `ClusterIssuers` (Let's Encrypt) are configured in Phase 3.

**External Secrets Operator** syncs secrets from AWS Secrets Manager into Kubernetes. The `ClusterSecretStore` is configured in Phase 3.

**CloudNativePG** is the PostgreSQL operator. Database clusters are defined in Phase 7.

---

## Roadmap

- [x] EKS provisioning (VPC, EKS, node group)
- [x] K8s infrastructure (Cilium, cert-manager, ESO, CNPG)
- [ ] GitOps (Flux v2)
- [ ] CNPG backup (Barman Cloud → S3)
- [ ] EKS hardening
- [ ] Monitoring (kube-prometheus-stack + Loki)
- [ ] Customer onboarding (multi-tenant n8n)
- [ ] GCP (Terraform + GKE)
- [ ] Azure (ARM + AKS)
