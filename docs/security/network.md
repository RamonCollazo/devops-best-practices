# Network Security

Reference: [AWS EKS Best Practices: Network Security](https://docs.aws.amazon.com/eks/latest/best-practices/network-security.html)

See [best-practices-traceability.md](best-practices-traceability.md) for a table mapping every best practice to the exact file and config.


## Implemented Practices

### 1. Default-Deny CiliumNetworkPolicy

**File:** `gitops/apps/aws/staging/acme/netpol-default-deny.yaml`

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
spec:
  endpointSelector: {}
  ingress:
    - {}
  egress:
    - {}
```

**What it does:**
An empty `endpointSelector` matches every pod in the namespace. A single empty rule `{}`
in both `ingress` and `egress` enables policy enforcement on both directions without
matching any traffic, effectively denying all flows not explicitly allowed by subsequent
policies.

**Why:**
Kubernetes allows all pod-to-pod traffic by default. Without a deny-all baseline, a
compromised pod can freely communicate with any other pod in the cluster, exfiltrate data
to the internet, or probe internal services. The default-deny policy is the foundation of
a least-privilege network posture: every allowed traffic flow must be justified and
explicitly declared.

This is the recommended starting point from the AWS EKS best practices guide and from
the Kubernetes NetworkPolicy documentation.


### 2. Allow DNS

**File:** `gitops/apps/aws/staging/acme/netpol-allow-dns.yaml`

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
```

**What it does:**
Allows all pods in the namespace to send DNS queries to the CoreDNS pods in `kube-system`.
Cilium automatically injects the `io.kubernetes.pod.namespace` label into every endpoint
identity, so combining it with `k8s-app: kube-dns` in a single `matchLabels` entry
restricts the destination to CoreDNS pods specifically, not the entire kube-system namespace.

**Why:**
Without DNS egress, pods cannot resolve service names or external hostnames, breaking
almost all application functionality. This policy must be added before any other allow
rules because DNS is a prerequisite for every subsequent network call.


### 3. Allow Gateway to Application (Ingress)

**File:** `gitops/apps/aws/staging/acme/netpol-allow-gateway-to-n8n.yaml`

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: n8n
  ingress:
    - fromEntities:
        - cluster
      toPorts:
        - ports:
            - port: "5678"
              protocol: TCP
```

**What it does:**
Allows inbound traffic to the n8n pod on port 5678 from any endpoint within the cluster.
All traffic originating outside the cluster boundary is blocked.

**Why:**
Cilium's Gateway API implementation uses an Envoy DaemonSet that runs with
`hostNetwork: true` in `kube-system`. Host-network pods share the node's network
namespace, so Cilium classifies their traffic as the `cluster` entity rather than a
namespace-scoped endpoint identity. Standard `namespaceSelector` or `ipBlock` selectors
cannot match this traffic - only `fromEntities: [cluster]` covers it correctly.

The `cluster` entity matches any endpoint known to Cilium within the cluster (pods, nodes,
host-network processes) while blocking all external sources. The security boundary for
external access is the ELB and Cilium Gateway, which enforce hostname, TLS, and routing
rules before proxying to the application.


### 4. Allow Application to Database (Egress)

**File:** `gitops/apps/aws/staging/acme/netpol-allow-n8n-to-db.yaml`

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: n8n
  egress:
    - toEndpoints:
        - matchLabels:
            cnpg.io/cluster: acme-db
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
```

**What it does:**
Allows the n8n pod to open TCP connections to CNPG cluster pods on port 5432
(PostgreSQL). The `cnpg.io/cluster` label is set by the CNPG operator on all pods
belonging to the named cluster.

**Why:**
The application needs database access and nothing else in the cluster. By selecting on the
`cnpg.io/cluster` label rather than an IP range, the policy remains correct as pods are
rescheduled. Any other egress within the cluster is blocked.


### 5. Allow Database Ingress from Application

**File:** `gitops/apps/aws/staging/acme/netpol-allow-n8n-ingress-to-db.yaml`

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
spec:
  endpointSelector:
    matchLabels:
      cnpg.io/cluster: acme-db
  ingress:
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/name: n8n
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
```

**What it does:**
Allows n8n pods to reach CNPG pods on port 5432. This is the ingress side of the
connection that pairs with the egress rule above.

**Why:**
TCP connections require both an egress rule on the source and an ingress rule on the
destination. The default-deny policy blocks all ingress including to CNPG pods. Without
this policy the database connection is rejected even though n8n has egress permission.


### 6. Allow CNPG Operator Access

**File:** `gitops/apps/aws/staging/acme/netpol-allow-cnpg-operator.yaml`

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
spec:
  endpointSelector:
    matchLabels:
      cnpg.io/cluster: acme-db
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: cnpg-system
      toPorts:
        - ports:
            - port: "8000"
              protocol: TCP
```

**What it does:**
Allows the CNPG operator (running in `cnpg-system`) to reach the instance manager HTTP
API on port 8000 of each PostgreSQL pod.

**Why:**
The CNPG operator uses the instance manager API for health checks, status extraction, and
lifecycle management. Without this policy the default-deny blocks the operator, causing
"HTTP communication issue" errors on the Cluster resource and preventing the cluster from
becoming healthy.


### 7. Allow Application HTTPS Egress

**File:** `gitops/apps/aws/staging/acme/netpol-allow-app-egress-https.yaml`

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: n8n
  egress:
    - toEntities:
        - world
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

**What it does:**
Allows the n8n pod to make outbound HTTPS connections to any destination outside the
cluster on port 443. `toEntities: [world]` covers all destinations beyond the cluster
boundary.

**Why:**
Workflow automation workloads make HTTPS calls to external APIs as part of their core
function. The Pod Identity credential endpoint (`169.254.170.23`) uses link-local
addressing and is outside the scope of network policy enforcement regardless.

Restricting egress to specific FQDNs is possible with Cilium's `toFQDNs` rules - see
Future Work below.


### 8. Allow Database HTTPS Egress (Backups)

**File:** `gitops/apps/aws/staging/acme/netpol-allow-cnpg-egress-https.yaml`

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
spec:
  endpointSelector:
    matchLabels:
      cnpg.io/cluster: acme-db
  egress:
    - toEntities:
        - world
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

**What it does:**
Allows CNPG cluster pods to make outbound HTTPS connections on port 443 for WAL archiving
and base backups to S3 via the Barman Cloud plugin.

**Why:**
CNPG instances need to write backups to S3 over HTTPS. Without this rule the Barman
plugin cannot connect to S3 and backups fail. CNPG pod AWS credentials are provided by
Pod Identity via link-local and are outside network policy scope.


## Traffic Map - acme Namespace

```
Internet
  |
  v
[Load Balancer]
  |  HTTPS:443
  v
[Cilium Envoy - kube-system, hostNetwork]
  |  TCP:5678
  v
[n8n pod]
  |  TCP:5432               TCP:443
  +---> [CNPG pod] -------> [S3 / AWS]
  |
  +---> [External APIs]    TCP:443

All pods:  UDP/TCP:53 -> [CoreDNS - kube-system]
```


## Not Applicable

- **Security Groups for Pods:** Workloads connect to in-cluster services (CNPG), not
  directly to AWS services via RDS-style endpoints. CiliumNetworkPolicy covers all
  required east-west flows without needing SGP.
- **Service mesh / mTLS:** Not implemented in this phase. TLS is terminated at the Gateway;
  traffic between the Gateway and the application pod is inside the VPC on private ENI IPs.


## Future Work

- **Cilium FQDN egress policies:** Replace the open port-443 egress rules with
  `CiliumNetworkPolicy` using `toFQDNs` to restrict n8n and CNPG egress to specific
  AWS service hostnames (e.g. `s3.us-east-1.amazonaws.com`).
- **Hubble monitoring:** Use the Cilium Hubble UI to observe actual traffic flows and
  verify that the deny-all policy is blocking unexpected connections.
- **NetworkPolicy on infrastructure namespaces:** Add default-deny + explicit allow
  policies to `cert-manager`, `cnpg-system`, and `flux-system` namespaces.
