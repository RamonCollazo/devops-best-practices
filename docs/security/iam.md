# IAM - Identity and Access Management

Reference: [AWS EKS Best Practices: IAM](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html)

---

## Implemented Practices

### 1. Cluster Access Management API (Access Entries)

**File:** `provision/aws/cloudformation/eks.yaml`

```yaml
AccessConfig:
  AuthenticationMode: API
  BootstrapClusterCreatorAdminPermissions: false
```

**What it does:**
Switches the cluster from the deprecated `aws-auth` ConfigMap to the EKS Access Entries API.
A dedicated `AWS::EKS::AccessEntry` resource grants `AmazonEKSClusterAdminPolicy` to the
deploying principal (set via `ADMIN_ROLE_ARN` in the Makefile).

**Why:**
The `aws-auth` ConfigMap is a hand-edited YAML file in `kube-system`. A formatting mistake
or an unauthorized edit can permanently lock all humans out of the cluster. Access Entries
are managed through the AWS API, are validated before being applied, appear in CloudTrail,
and can be managed by CloudFormation - the same tools used for the rest of the
infrastructure. There is no separate "Kubernetes YAML editing" step required for access
management.

Setting `BootstrapClusterCreatorAdminPermissions: false` removes the implicit permanent
cluster-admin binding that EKS normally grants to the IAM identity that ran `create-cluster`.
Without this flag, whoever deployed the cluster retains superuser access forever, even if
their role is removed from your access policies. With this flag, every principal's access
is explicit and auditable.

---

### 2. EKS Pod Identities (over IRSA)

**Files:** `provision/aws/cloudformation/iam.yaml`, `provision/aws/cloudformation/s3.yaml`

**What it does:**
Both the n8n service account (reads Secrets Manager) and the CNPG cluster service account
(writes S3 backups) receive short-lived AWS credentials via the EKS Pod Identity Agent,
not hardcoded keys or instance profiles.

**Why:**
Pod Identity is the current AWS recommendation (2025+) over IRSA for same-account access.
It does not require an OIDC provider per cluster, uses a single reusable trust policy
(`Service: pods.eks.amazonaws.com`), and includes session tags (`kubernetes-namespace`,
`kubernetes-service-account`, `eks-cluster-arn`) that enable ABAC policies without creating
additional roles. Applications use the standard AWS credential provider chain with no SDK
modifications needed.

See also: `patterns.md` - EKS Pod Identity section.

---

### 3. Least-Privilege Secrets Manager Resource Scope

**File:** `provision/aws/cloudformation/iam.yaml`

```yaml
Resource: !Sub 'arn:aws:secretsmanager:${AWS::Region}:${AWS::AccountId}:secret:*-n8n-*'
```

**What it does:**
Restricts the `SecretsReaderRole` policy to secrets whose names match the pattern
`*-n8n-*` (e.g. `acme-n8n-db-user`, `acme-n8n-db-password`, `acme-n8n-encryption-key`).
The trailing wildcard covers the random 6-character suffix that AWS appends to secret ARNs.

**Why:**
`Resource: '*'` on a `GetSecretValue` action grants access to every secret in the account,
including database passwords, API keys, and any other secrets belonging to unrelated services.
If an n8n pod is compromised, the blast radius is limited to secrets following the
`*-n8n-*` naming convention. This pattern also supports multi-tenancy: any new customer
following the convention (`<customer>-n8n-*`) is automatically covered without changing
the IAM policy.

---

### 4. IMDSv2 Enforcement on Worker Nodes

**File:** `provision/aws/cloudformation/nodegroup.yaml`

```yaml
NodeLaunchTemplate:
  Type: AWS::EC2::LaunchTemplate
  Properties:
    LaunchTemplateData:
      MetadataOptions:
        HttpEndpoint: enabled
        HttpTokens: required        # IMDSv1 disabled
        HttpPutResponseHopLimit: 2  # containers can reach IMDS
```

**What it does:**
Sets IMDSv2 (token-based metadata access) as the only allowed mode on every worker node.
The hop limit of 2 allows containers running on the node to still reach the Instance
Metadata Service when needed, because the container's request traverses an extra network
hop through the host network namespace.

**Why:**
IMDSv1 is vulnerable to server-side request forgery (SSRF): a single HTTP GET to
`http://169.254.169.254/latest/meta-data/iam/security-credentials/<role>` from any
container on the node yields the node's IAM role credentials. IMDSv2 requires a PUT
request with a session token first, which browsers and typical SSRF gadgets cannot perform.
Even though app pods use Pod Identity (not the instance profile), the node role still holds
broad EC2 and EKS permissions - keeping it inaccessible to containers is a critical
defense-in-depth measure.

A hop limit of 1 would block containers from reaching IMDS entirely. A limit of 2 is the
AWS-recommended value for EKS nodes: safe because the Pod Identity Agent communicates over
a local socket, not IMDS.

---

### 5. Disable Service Account Token Automounting

**File:** `gitops/apps/aws/staging/acme/serviceaccount.yaml`

```yaml
automountServiceAccountToken: false
```

**File:** `gitops/apps/aws/staging/acme/values.yaml`

```yaml
serviceAccount:
  create: false  # Kustomize owns this SA
  name: n8n
```

**What it does:**
Prevents Kubernetes from projecting a service account token into every n8n pod as a file at
`/var/run/secrets/kubernetes.io/serviceaccount/token`. The Helm chart is told not to create
the SA so `serviceaccount.yaml` is the single authoritative source.

**Why:**
A projected service account token is a valid Kubernetes API credential. If an attacker gains
a shell in the n8n container (e.g. via a malicious workflow or a dependency vulnerability),
the token can be used to authenticate against the Kubernetes API and perform actions allowed
by the service account's RBAC bindings. n8n has no legitimate need to call the Kubernetes
API, so mounting the token is unnecessary exposure. Disabling it at the ServiceAccount level
ensures the setting applies regardless of how the pod is created.

---

## Not Applicable

- **aws-node IRSA (Practice 11):** Cilium replaces `aws-node`; the `vpc-cni` DaemonSet is
  not installed (`BootstrapSelfManagedAddons: false`). There is no aws-node to configure.

---

## Future Work

- **Anonymous API access:** The default `system:discovery` and `system:basic-user`
  ClusterRoleBindings include `system:unauthenticated`. These should be edited to remove
  the unauthenticated group for clusters that do not require public API discovery.
- **ABAC on S3 backup policy:** The `CnpgBackupRole` in `s3.yaml` uses `Resource: bucket/*`.
  Consider adding session-tag conditions (`aws:PrincipalTag/kubernetes-namespace`) to
  restrict each customer's CNPG pod to its own S3 prefix.
