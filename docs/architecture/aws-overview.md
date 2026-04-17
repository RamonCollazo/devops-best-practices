# AWS Architecture Overview


## Infrastructure Layers

```
+----------------------------------------------------------+
|  CloudFormation                                          |
|  vpc.yaml  eks.yaml  nodegroup.yaml  iam.yaml  s3.yaml  |
+----------------------------------------------------------+
|  Kubernetes (EKS)                                        |
|  Cilium CNI  |  cert-manager  |  CNPG operator          |
|  Flux v2 GitOps                                          |
+----------------------------------------------------------+
|  Applications (per customer namespace)                   |
|  n8n  |  CNPG cluster  |  CiliumNetworkPolicies         |
+----------------------------------------------------------+
|  Monitoring (monitoring namespace)                       |
|  Prometheus  |  Grafana  |  Loki  |  Promtail           |
+----------------------------------------------------------+
```


## Network Topology

```
Region: us-east-1
VPC: 10.0.0.0/16

  AZ-a                AZ-b                AZ-c
  +-----------------+ +-----------------+ +-----------------+
  | Public subnet   | | Public subnet   | | Public subnet   |
  | NAT Gateway     | | NAT Gateway     | | NAT Gateway     |
  |   ELB nodes     | |   ELB nodes     | |   ELB nodes     |
  +-----------------+ +-----------------+ +-----------------+
  +-----------------+ +-----------------+ +-----------------+
  | Private subnet  | | Private subnet  | | Private subnet  |
  | EKS nodes       | | EKS nodes       | | EKS nodes       |
  | Bottlerocket    | | Bottlerocket    | | Bottlerocket    |
  | m5.xlarge       | | m5.xlarge       | | m5.xlarge       |
  +-----------------+ +-----------------+ +-----------------+
```

Cilium runs in **ENI mode**: pods receive real VPC IP addresses allocated directly from the
node's Elastic Network Interfaces. There is no overlay network. Pod-to-pod traffic is native
VPC routing. `aws-node` and `kube-proxy` DaemonSets are not deployed.


## CloudFormation Stacks

| Stack | Depends on | What it creates |
|-------|------------|----------------|
| `vpc` | - | VPC, subnets, NAT gateways, route tables |
| `eks` | `vpc` | EKS cluster, OIDC provider, CoreDNS, EBS CSI driver, Secrets Store CSI driver, Pod Identity agent, GuardDuty detector |
| `s3` | - | Backup bucket + `CnpgBackupRole` (Pod Identity) |
| `nodegroup` | `eks`, `s3` | Managed node group, node IAM role, Cilium ENI inline policy, encrypted gp3 root volume |
| `iam` | `eks` | `SecretsReaderRole` (Pod Identity for n8n) |

Deploy order: `vpc` -> `eks` + `s3` (parallel) -> `nodegroup` -> `iam`


## Kubernetes Architecture

### Node configuration

- OS: Bottlerocket (immutable, SELinux-enforced, verified boot)
- Instance: m5.xlarge (4 vCPU, 16 GB RAM)
- Placement: private subnets only
- IMDSv2 enforced (hop limit 2 for pod access)
- Root volume: encrypted gp3

### CNI - Cilium

Cilium replaces both `aws-node` (VPC CNI) and `kube-proxy`. It provides:

- Pod networking via ENI (no overlay, native VPC routing)
- eBPF-based kube-proxy replacement (no iptables)
- Kubernetes Gateway API implementation (Envoy DaemonSet)
- Network policy enforcement (CiliumNetworkPolicy + standard NetworkPolicy)
- Hubble observability

### EKS add-ons

| Add-on | Purpose |
|--------|---------|
| CoreDNS | In-cluster DNS |
| EBS CSI driver | Persistent volume provisioning |
| Secrets Store CSI driver | AWS Secrets Manager -> K8s Secret sync |
| Pod Identity agent | Short-lived AWS credentials injected into pods |
| GuardDuty agent | Runtime threat detection (EKS audit logs + runtime monitoring) |


## GitOps Architecture

Flux v2 reconciles the cluster state from this repository. The reconciliation chain
enforces ordering: each layer waits for the previous one to be healthy (`wait: true`).

```
infrastructure-controllers
  HelmRelease: Cilium
  HelmRelease: cert-manager
  HelmRelease: CNPG operator
        |
        v
infrastructure-configs
  Gateway (shared-gateway namespace)
  ClusterIssuer (Let's Encrypt)
        |
        +-----> apps
        |         Per-customer namespace
        |         (CNPG cluster, n8n HelmRelease, HTTPRoute, CiliumNetworkPolicies)
        |
        +-----> monitoring-controllers
                  HelmRelease: kube-prometheus-stack
                  HelmRelease: Loki
                  HelmRelease: Promtail
                        |
                        v
                  monitoring-configs
                    Certificate + HTTPRoute for Grafana
```

### Repository layout

```
clusters/aws/staging/
  infrastructure.yaml   # Flux Kustomization: controllers -> configs
  apps.yaml             # Flux Kustomization: apps (depends on configs)

gitops/
  infrastructure/
    controllers/        # HelmReleases: Cilium, cert-manager, CNPG
    configs/
      base/             # Gateway, ClusterIssuer
      aws/staging/      # Kustomize overlay for staging
  apps/
    aws/staging/
      acme/             # Reference customer implementation
```


## Application Architecture (per customer)

Each customer is isolated in its own namespace. The `acme` namespace is the reference
implementation.

```
namespace: acme
+------------------------------------------------------------------+
|                                                                  |
|  [ServiceAccount: n8n]                                           |
|    Pod Identity -> SecretsReaderRole -> Secrets Manager          |
|                                                                  |
|  [SecretProviderClass: acme-secrets]                             |
|    Pulls 3 secrets from Secrets Manager                          |
|    Syncs them as K8s Secrets (CSI volume mount triggers sync)    |
|                                                                  |
|  [CNPG Cluster: acme-db]                                         |
|    PostgreSQL, bootstrapped from acme-db-credentials secret      |
|    WAL archiving + base backups -> S3 via Barman Cloud plugin    |
|    Pod Identity -> CnpgBackupRole -> S3 bucket                   |
|                                                                  |
|  [HelmRelease: n8n]                                              |
|    Reads DB credentials from acme-n8n-db K8s Secret             |
|    Reads encryption key from acme-n8n-secrets K8s Secret        |
|    readOnlyRootFilesystem, runAsNonRoot, no capabilities         |
|                                                                  |
|  [Certificate: acme-tls]                                         |
|    Issued in shared-gateway namespace                            |
|    Let's Encrypt HTTP01 via GatewayHTTPRoute                     |
|                                                                  |
|  [HTTPRoute: n8n]                                                |
|    Host: acme.<domain>                                           |
|    Attached to shared Gateway                                    |
|    Routes HTTPS:443 -> n8n:5678                                  |
|                                                                  |
+------------------------------------------------------------------+
```


## Traffic Flows

### External request (HTTPS)

```
Client
  | HTTPS:443
  v
AWS ELB (public subnet)
  | TLS termination
  v
Cilium Envoy DaemonSet (kube-system, hostNetwork)
  | TCP:5678  [CiliumNetworkPolicy: allow-gateway-to-n8n, fromEntities: cluster]
  v
n8n pod (private subnet, ENI IP)
  | TCP:5432  [CiliumNetworkPolicy: allow-n8n-to-db]
  v
CNPG pod (acme-db)
```

### Backup flow

```
CNPG pod
  | HTTPS:443  [CiliumNetworkPolicy: allow-cnpg-egress-https, toEntities: world]
  v
S3 bucket (devops-best-practices-staging-cnpg-backups)
  credentials: Pod Identity -> CnpgBackupRole (no static keys)
```

### DNS resolution (all pods)

```
Any pod
  | UDP/TCP:53  [CiliumNetworkPolicy: allow-dns, toEndpoints: kube-system/kube-dns]
  v
CoreDNS (kube-system)
```


## Network Policy Model

All pods in customer namespaces operate under a **default-deny** baseline.
Traffic is allowed only by explicit CiliumNetworkPolicy rules.

| Policy | Selector | Direction | Allows |
|--------|----------|-----------|--------|
| `default-deny` | all pods | ingress + egress | nothing (enforcement baseline) |
| `allow-dns` | all pods | egress | UDP/TCP:53 to CoreDNS |
| `allow-gateway-to-n8n` | n8n | ingress | TCP:5678 from `cluster` entity |
| `allow-n8n-to-db` | n8n | egress | TCP:5432 to CNPG pods |
| `allow-n8n-ingress-to-db` | CNPG pods | ingress | TCP:5432 from n8n |
| `allow-cnpg-operator` | CNPG pods | ingress | TCP:8000 from cnpg-system |
| `allow-app-egress-https` | n8n | egress | TCP:443 to world |
| `allow-cnpg-egress-https` | CNPG pods | egress | TCP:443 to world |

The `allow-gateway-to-n8n` policy uses `fromEntities: [cluster]` because Cilium Envoy runs
with `hostNetwork: true`. Host-network processes are classified by Cilium as the `cluster`
entity, which cannot be matched by standard namespace or IP selectors.


## Secrets Architecture

No static credentials are stored in the repository or in etcd.

```
AWS Secrets Manager
  acme-n8n-db-user          (CNPG DB owner username)
  acme-n8n-db-password      (CNPG DB owner password + n8n DB connection)
  acme-n8n-encryption-key   (n8n N8N_ENCRYPTION_KEY)
        |
        | EKS Pod Identity (SecretsReaderRole)
        v
Secrets Store CSI Driver
  SecretProviderClass: acme-secrets
        |
        | CSI volume mount (triggers sync on pod start)
        v
K8s Secrets (created by CSI driver, not stored in Git)
  acme-db-credentials       -> CNPG cluster bootstrap
  acme-n8n-db              -> n8n DB connection
  acme-n8n-secrets         -> n8n encryption key
```

Pod Identity injects short-lived AWS credentials into the pod at runtime. No IAM role
annotations on the ServiceAccount are required.
