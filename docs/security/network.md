# Network Security

Reference: [AWS EKS Best Practices: Network Security](https://docs.aws.amazon.com/eks/latest/best-practices/network-security.html)

---

## Implemented Practices

### 1. Default-Deny NetworkPolicy

**File:** `gitops/apps/aws/staging/acme/netpol-default-deny.yaml`

```yaml
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

**What it does:**
A single NetworkPolicy with an empty `podSelector` (matches all pods) and no rules denies
all ingress and egress traffic for every pod in the namespace. Subsequent policies add back
only the specific flows that are explicitly required.

**Why:**
Kubernetes allows all pod-to-pod traffic by default. Without a deny-all baseline, a
compromised pod can freely communicate with any other pod in the cluster, exfiltrate data
to the internet, or probe internal services. The default-deny policy is the foundation of
a least-privilege network posture: every allowed traffic flow must be justified and
explicitly declared.

This is the recommended starting point from the AWS EKS best practices guide and from
the Kubernetes NetworkPolicy documentation.

---

### 2. Allow DNS

**File:** `gitops/apps/aws/staging/acme/netpol-allow-dns.yaml`

```yaml
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
        podSelector:
          matchLabels:
            k8s-app: kube-dns
    ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
```

**What it does:**
Allows all pods in the namespace to send DNS queries to the CoreDNS pods in `kube-system`.
The combined `namespaceSelector` + `podSelector` restricts the destination to CoreDNS pods
specifically, not the entire kube-system namespace.

**Why:**
Without DNS egress, pods cannot resolve service names or external hostnames, breaking
almost all application functionality. This policy must be added before any other allow
rules because DNS is a prerequisite for every subsequent network call. It is kept separate
from other rules so its purpose is explicit and it is easy to audit.

---

### 3. Allow Gateway to Application (Ingress)

**File:** `gitops/apps/aws/staging/acme/netpol-allow-gateway-to-n8n.yaml`

```yaml
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: n8n
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: shared-gateway
      ports:
        - protocol: TCP
          port: 5678
```

**What it does:**
Allows inbound traffic to the application pod on its service port only from two namespaces:
`kube-system` and `shared-gateway`. All other sources are blocked.

**Why:**
With Cilium Gateway API enabled (`gatewayAPI.enabled: true`), traffic from the load
balancer is processed by a Cilium Envoy proxy DaemonSet running in `kube-system`. The
source namespace seen at NetworkPolicy enforcement is `kube-system`, not the client's
origin. `shared-gateway` is included to cover direct-forwarding proxy modes. No other pod
or namespace should be able to reach the application directly.

This is the platform-level template for the ingress policy of any customer application:
allow traffic only from the Gateway, block all other inbound connections.

---

### 4. Allow Application to Database (Egress)

**File:** `gitops/apps/aws/staging/acme/netpol-allow-n8n-to-db.yaml`

```yaml
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: n8n
  egress:
    - to:
        - podSelector:
            matchLabels:
              cnpg.io/cluster: acme-db
      ports:
        - protocol: TCP
          port: 5432
```

**What it does:**
Allows the application pod to open TCP connections to CNPG cluster pods on port 5432
(PostgreSQL). The `cnpg.io/cluster` label is set by the CNPG operator on all pods
belonging to the named cluster.

**Why:**
The application needs database access and nothing else in the cluster. By selecting on the
`cnpg.io/cluster` label rather than an IP range, the policy remains correct as pods are
rescheduled. Any other egress within the cluster is blocked: the application cannot reach
other namespaces, the Kubernetes API server, or other services.

---

### 5. Allow Application HTTPS Egress

**File:** `gitops/apps/aws/staging/acme/netpol-allow-app-egress-https.yaml`

```yaml
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: n8n
  egress:
    - ports:
        - protocol: TCP
          port: 443
```

**What it does:**
Allows the application pod to make outbound HTTPS connections to any destination on port
443. No destination selector is applied, meaning any IP is reachable on this port.

**Why:**
Workflow automation and other application workloads make HTTPS calls to external APIs as
part of their core function. Blocking port 443 egress would break the application entirely.
The Pod Identity credential endpoint (`http://169.254.170.23`) uses link-local addressing
and is outside the scope of NetworkPolicy enforcement regardless.

Restricting egress to specific FQDN destinations (e.g. only AWS service endpoints) is
possible with Cilium's `CiliumNetworkPolicy` using `toFQDNs` rules. This is noted in
Future Work below but not implemented here to keep the baseline simple and portable
across CNI implementations.

---

### 6. Allow Database HTTPS Egress (Backups)

**File:** `gitops/apps/aws/staging/acme/netpol-allow-cnpg-egress-https.yaml`

```yaml
spec:
  podSelector:
    matchLabels:
      cnpg.io/cluster: acme-db
  egress:
    - ports:
        - protocol: TCP
          port: 443
```

**What it does:**
Allows CNPG cluster pods to make outbound HTTPS connections on port 443 for WAL archiving
and base backups to S3 via the Barman Cloud plugin.

**Why:**
CNPG instances need to write backups to S3. This traffic exits the cluster to AWS service
endpoints over HTTPS. Without this rule the Barman plugin cannot connect to S3 and backups
will fail. The CNPG pod's AWS credentials are provided by Pod Identity via link-local and
are outside NetworkPolicy scope.

---

## Traffic Map - acme Namespace

```
Internet
  |
  v
[Load Balancer]
  |  HTTPS:443
  v
[Cilium Envoy - kube-system]
  |  TCP:5678
  v
[n8n pod]
  |  TCP:5432               TCP:443
  +---> [CNPG pod] -------> [S3 / AWS]
  |
  +---> [External APIs]    TCP:443
```

All pods:  UDP/TCP:53 -> [CoreDNS - kube-system]

---

## Not Applicable

- **Security Groups for Pods:** Our workloads connect to in-cluster services (CNPG), not
  directly to AWS services via RDS-style endpoints. Standard NetworkPolicy covers all
  required east-west flows without needing SGP.
- **Service mesh / mTLS:** Not implemented in this phase. TLS is terminated at the Gateway;
  traffic between the Gateway and the application pod is inside the VPC on private ENI IPs.

---

## Future Work

- **Cilium FQDN egress policies:** Replace the open port-443 egress rules with
  `CiliumNetworkPolicy` using `toFQDNs` to restrict n8n and CNPG egress to specific
  AWS service hostnames (e.g. `s3.us-east-1.amazonaws.com`).
- **Hubble monitoring:** Use the Cilium Hubble UI (already enabled) to observe actual
  traffic flows and verify that the deny-all policy is blocking unexpected connections.
- **NetworkPolicy on infrastructure namespaces:** Add default-deny + explicit allow
  policies to `cert-manager`, `cnpg-system`, and `flux-system` namespaces.
