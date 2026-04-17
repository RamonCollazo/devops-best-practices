# IAM - Identity and Access Management

References:
- [AWS EKS Best Practices: IAM](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html)
- [AWS EKS Best Practices: Cluster Access Management](https://docs.aws.amazon.com/eks/latest/best-practices/cluster-access-management.html)

See [best-practices-traceability.md](best-practices-traceability.md) for a table mapping every best practice to the exact file and config.


## Implemented Practices

### 1. Cluster Access Management API (Access Entries)

**File:** `provision/aws/cloudformation/eks.yaml`

```yaml
AccessConfig:
  AuthenticationMode: API
  BootstrapClusterCreatorAdminPermissions: false
```

**What it does:**
Switches the cluster from the deprecated `aws-auth` ConfigMap to the EKS Access Entries
API. A dedicated `AWS::EKS::AccessEntry` resource grants `AmazonEKSClusterAdminPolicy`
to the deploying principal (set via `ADMIN_ROLE_ARN` in the Makefile).

**Why not aws-auth ConfigMap?**
The `aws-auth` ConfigMap is a hand-edited YAML file in `kube-system`. A formatting mistake
or unauthorized edit can permanently lock all humans out of the cluster, and there is no
recovery path without AWS support. Access Entries are managed through the AWS API:
- They are validated by the API before being applied (no silent syntax errors)
- They appear in CloudTrail (who granted access, when, from where)
- They can be managed by CloudFormation alongside the rest of the infrastructure
- Mistakes can be corrected through the API without touching `kubectl`

**Why BootstrapClusterCreatorAdminPermissions: false?**
By default, EKS grants permanent cluster-admin to whichever IAM identity ran
`create-cluster`. This binding persists even if that identity is later removed from your
access policies. Setting this to `false` removes the implicit grant: every principal's
access is explicit, auditable, and revocable. The `AdminAccessEntry` resource in the same
template grants cluster-admin to the `ADMIN_ROLE_ARN` explicitly.


### 2. EKS Pod Identity (over IRSA)

**Files:** `provision/aws/cloudformation/iam.yaml`, `provision/aws/cloudformation/s3.yaml`

**What it does:**
Both the n8n service account (reads Secrets Manager) and the CNPG cluster service account
(writes S3 backups) receive short-lived AWS credentials via the EKS Pod Identity Agent.
No hardcoded keys, no instance profiles, no OIDC annotations on the ServiceAccount.

The Pod Identity Agent runs as a DaemonSet on each node (installed as an EKS add-on). It
intercepts credential requests from pods via a local socket and exchanges the pod's
identity for short-lived STS credentials scoped to the configured IAM role.

**Why Pod Identity over IRSA?**
Pod Identity is the current AWS recommendation (released GA in 2023) for same-account
access. Key advantages over IRSA:

| | IRSA | Pod Identity |
|--|------|--------------|
| OIDC provider | Required per cluster | Not required |
| Trust policy | References OIDC issuer URL (changes per cluster) | Reusable: `Service: pods.eks.amazonaws.com` |
| SA annotation | Required | Not required |
| Session tags | Not included | Automatic (`kubernetes-namespace`, `kubernetes-service-account`, `eks-cluster-arn`) |
| Cross-account | Yes | Requires additional configuration |

The automatic session tags enable ABAC (Attribute-Based Access Control) policies. For
example, a future ABAC policy on the S3 backup role could restrict each customer's CNPG
pod to its own S3 prefix using `aws:PrincipalTag/kubernetes-namespace`.

**How to create a Pod Identity association:**
```bash
# n8n pod -> SecretsReaderRole
make create-pod-identity-association NAMESPACE=<customer>

# CNPG pod -> CnpgBackupRole
make create-cnpg-backup-association NAMESPACE=<customer>
```


### 3. Least-Privilege Secrets Manager Resource Scope

**File:** `provision/aws/cloudformation/iam.yaml`

```yaml
Resource: !Sub 'arn:aws:secretsmanager:${AWS::Region}:${AWS::AccountId}:secret:*-n8n-*'
```

**What it does:**
Restricts the `SecretsReaderRole` policy to secrets whose names match the pattern
`*-n8n-*`. The trailing wildcard after `*-n8n-*` is required because AWS appends a
random 6-character suffix to all secret ARNs (e.g. `acme-n8n-db-user-aBcDeF`).

**Why not Resource: "*"?**
`Resource: "*"` on `secretsmanager:GetSecretValue` grants access to every secret in the
account, including database passwords, API keys, and credentials for unrelated services.
If an n8n pod is compromised, the attacker could read all secrets in the account.

The `*-n8n-*` pattern limits the blast radius to secrets following the per-customer n8n
naming convention. It also supports multi-tenancy: a new customer `beta` with secrets
named `beta-n8n-db-user` is automatically covered without changing the IAM policy.

**What actions are granted?**
- `secretsmanager:GetSecretValue`: read the secret value (required for mounting)
- `secretsmanager:DescribeSecret`: read metadata/ARN (required by the CSI driver)
- `secretsmanager:ListSecretVersionIds`: list versions (required for rotation support)

Write operations (`CreateSecret`, `PutSecretValue`, `DeleteSecret`) are not granted.


### 4. IMDSv2 Enforcement on Worker Nodes

**File:** `provision/aws/cloudformation/nodegroup.yaml`

```yaml
MetadataOptions:
  HttpEndpoint: enabled
  HttpTokens: required
  HttpPutResponseHopLimit: 2
```

**What it does:**
Enforces IMDSv2 (Instance Metadata Service version 2) on all worker nodes. IMDSv2
requires a PUT request with a session token before any metadata can be read. The hop
limit of 2 allows containers running inside pods to reach the IMDS through the host
network namespace.

**Why disable IMDSv1?**
IMDSv1 is vulnerable to Server-Side Request Forgery (SSRF). A single HTTP GET to
`http://169.254.169.254/latest/meta-data/iam/security-credentials/<role>` from any
container on the node yields the node IAM role's credentials. SSRF vulnerabilities are
common in web applications; IMDSv1 turns an application-level bug into a full node
credential compromise.

IMDSv2 requires a PUT request with a `TTL-1` token first, which browsers and typical SSRF
gadgets cannot perform.

**Why hop limit 2 instead of 1?**
A hop limit of 1 would prevent containers from reaching IMDS entirely. Even though
application pods use Pod Identity (not the instance profile), the Pod Identity Agent
itself communicates via a local socket, not IMDS, so a hop limit of 1 is technically
safe for Pod Identity. However, other AWS tooling (e.g. the EBS CSI driver's node
component) may need IMDS access. A hop limit of 2 is the AWS-recommended value for EKS
nodes: it allows containers to reach IMDS when needed while preventing multi-hop SSRF
that could traverse multiple NAT layers.

**Why keep HttpEndpoint enabled?**
The Pod Identity Agent uses the IMDS endpoint to operate. Disabling IMDS entirely
(`HttpEndpoint: disabled`) would break Pod Identity credential delivery.


### 5. Disable Service Account Token Automounting

**File:** `gitops/apps/aws/staging/acme/serviceaccount.yaml`

```yaml
automountServiceAccountToken: false
```

**File:** `gitops/apps/aws/staging/acme/values.yaml`

```yaml
serviceAccount:
  create: false
  name: n8n
```

**What it does:**
Prevents Kubernetes from projecting a service account token into n8n pods as a file at
`/var/run/secrets/kubernetes.io/serviceaccount/token`. The Helm chart is told not to
create the ServiceAccount (`create: false`) so `serviceaccount.yaml` is the single
authoritative source for this resource.

**Why disable token automounting?**
A projected service account token is a valid Kubernetes API credential. If an attacker
gains a shell in the n8n container (via a malicious workflow or a dependency
vulnerability), they can use the token to authenticate against the Kubernetes API and
perform actions allowed by the service account's RBAC bindings. n8n has no legitimate
need to call the Kubernetes API, so mounting the token is unnecessary exposure.

Disabling at the ServiceAccount level ensures the setting applies regardless of how the
pod is created (Helm, kubectl apply, controller). Setting `serviceAccount.create: false`
in the Helm values prevents a race where Helm would create a new SA (with the default
automount behavior) and override the Kustomize-managed one.

**Why not just rely on RBAC with no permissions?**
An SA with no RBAC bindings still produces a valid token. A valid token that authorizes
nothing can still be used to enumerate cluster resources via the `system:discovery`
ClusterRoleBinding that exists by default. Mounting no token is strictly better than
mounting a token with no permissions.


## Not Applicable

- **aws-node IRSA:** Cilium replaces `aws-node`; the VPC CNI DaemonSet is not installed
  (`BootstrapSelfManagedAddons: false`). There is no aws-node SA to configure.


## Future Work

- **ABAC on S3 backup policy:** The `CnpgBackupRole` uses `Resource: bucket/*`. Add
  a `Condition` on `aws:PrincipalTag/kubernetes-namespace` to restrict each customer's
  CNPG pod to its own S3 prefix (`s3://bucket/<namespace>/`), preventing a compromised
  pod from accessing other customers' backups.
- **Remove system:unauthenticated from discovery:** The default `system:discovery` and
  `system:basic-user` ClusterRoleBindings include `system:unauthenticated`. For clusters
  that do not require public API discovery, remove the unauthenticated group from these
  bindings to prevent credential-free cluster enumeration.
