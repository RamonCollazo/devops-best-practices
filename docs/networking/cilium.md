# Networking: Cilium

References:
- [Cilium documentation](https://docs.cilium.io/)
- [Cilium ENI mode for AWS](https://docs.cilium.io/en/stable/network/concepts/ipam/eni/)
- [Cilium Gateway API](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)
- [AWS EKS Best Practices: Networking](https://docs.aws.amazon.com/eks/latest/best-practices/networking.html)


## Overview

Cilium replaces both the default AWS VPC CNI (`aws-node`) and `kube-proxy` on this
cluster. It provides pod networking, network policy enforcement, the Gateway API
implementation, and cluster observability via Hubble.


## Why Cilium Instead of VPC CNI?

AWS VPC CNI (`aws-node`) is the default EKS networking plugin. Cilium replaces it for
several reasons:

**eBPF-based dataplane:**
Cilium uses eBPF programs loaded into the Linux kernel to handle packet processing.
Traditional networking stacks use iptables rules managed by kube-proxy. iptables has
O(n) performance, adding a new Service or NetworkPolicy rule requires rewriting and
re-reading the entire iptables ruleset. eBPF uses hash-based lookups that scale
independently of the number of rules.

**kube-proxy replacement:**
Cilium replaces kube-proxy entirely. Service load balancing, NodePort, ExternalIPs, and
session affinity are all handled by Cilium's eBPF programs. This eliminates iptables-based
connection tracking for Service traffic.

**Network policy with identity:**
Cilium uses cryptographic identities per pod (based on Kubernetes labels) rather than
IP-based rules. When a pod is rescheduled to a new IP, its identity stays the same —
network policy evaluation is not affected. Standard Kubernetes NetworkPolicy and
CiliumNetworkPolicy (a superset) are both supported.

**Gateway API implementation:**
Cilium ships a built-in Envoy-based Gateway API controller. The same Cilium installation
provides pod networking, policy enforcement, and ingress, no separate ingress controller
is needed.


## ENI Mode

**File:** `gitops/infrastructure/controllers/base/cilium/values.yaml`

```yaml
eni:
  enabled: true
ipam:
  mode: eni
```

In ENI mode, Cilium allocates pod IPs directly from the node's Elastic Network Interfaces
(ENIs) in the VPC. Each pod gets a real VPC IP address, there is no overlay network and
no VXLAN or GENEVE encapsulation.

**Why ENI mode?**
- **No overlay overhead:** Pod-to-pod traffic is native VPC routing. There is no
  encapsulation/decapsulation cost, no MTU reduction, and no per-hop overhead.
- **VPC-native IPs:** Every pod is directly addressable within the VPC. Security groups,
  VPC flow logs, and AWS routing all see pod IPs directly, not translated node IPs.
- **Consistent with AWS networking model:** RDS, ElastiCache, and other AWS services can
  be reached directly from pods by IP without NAT.

**Why does ENI mode require a custom IAM policy on the node role?**
Cilium needs to call EC2 APIs to create, attach, and manage ENIs, and to assign/unassign
private IP addresses from those ENIs. The standard `AmazonEKS_CNI_Policy` (used by
`aws-node`) does not cover all required actions. A custom `CiliumENI` inline policy in
`nodegroup.yaml` grants the exact set of EC2 actions Cilium needs.

**Why are aws-node and kube-proxy not installed?**
`BootstrapSelfManagedAddons: false` in the EKS cluster spec tells EKS not to deploy the
default self-managed add-ons including `aws-node` and `kube-proxy`. This prevents
conflicts with Cilium. CoreDNS is installed separately as a managed add-on, it is not
affected by this setting.


## Bootstrap Order

Cilium must be running before nodes join the cluster. Kubernetes nodes are only marked
`Ready` once a CNI plugin is present and has configured the network interface. Without
Cilium:
1. Nodes join the cluster
2. Kubelet tries to start pods
3. CNI call fails, no plugin present
4. Pods (including Flux, cert-manager) fail to start
5. The cluster is stuck

The correct order:

```
deploy-eks                (cluster API available, no nodes yet)
     |
install-gateway-api-crds  (CRDs must exist before Cilium starts its Gateway controller)
     |
install-cilium            (manual Helm install, Cilium starts without any nodes)
     |
deploy-nodegroup          (nodes join, Cilium assigns ENI IPs immediately)
```

**Why is Cilium installed manually (not by Flux)?**
Flux itself runs as pods that need networking to start. Cilium must exist before Flux
can run. This is the bootstrap dependency: the tool that manages Cilium cannot start
without Cilium. The manual `make install-cilium` breaks this circular dependency.

After bootstrap, Flux takes over Cilium management via HelmRelease. If you need to update
Cilium, update the chart version in the HelmRelease, Flux will reconcile it without
manual intervention.

**Why install Gateway API CRDs before Cilium?**
Cilium's Helm chart validates the presence of Gateway API CRDs (`Gateway`,
`GatewayClass`, `HTTPRoute`) at install time when `gatewayAPI.enabled: true`. If the
CRDs are not present, the Cilium install fails. Gateway API CRDs are installed via a
standalone manifest (`make install-gateway-api-crds`) before Cilium.


## kube-proxy Replacement

**File:** `gitops/infrastructure/controllers/base/cilium/values.yaml`

```yaml
kubeProxyReplacement: true
k8sServiceHost: "${k8sServiceHost}"
k8sServicePort: 443
```

With `kubeProxyReplacement: true`, Cilium handles all Service traffic using eBPF programs
instead of iptables rules. `k8sServiceHost` and `k8sServicePort` point Cilium to the EKS
API server, Cilium needs to watch Kubernetes Services and Endpoints to build its eBPF
maps.

The `k8sServiceHost` value is injected at reconcile time by Flux from the `cluster-vars`
ConfigMap (set via `make create-cluster-vars`). This avoids hardcoding the API server
endpoint in the repository.


## Gateway API

**File:** `gitops/infrastructure/controllers/base/cilium/values.yaml`

```yaml
gatewayAPI:
  enabled: true
```

Cilium's Gateway API implementation deploys an Envoy proxy as a DaemonSet in
`kube-system`. When a `Gateway` resource is created, Cilium provisions an AWS Load
Balancer (NLB) and configures Envoy to route traffic to the backend services specified
in `HTTPRoute` resources.

**Why a shared Gateway instead of one per customer?**
A single `Gateway` in the `shared-gateway` namespace handles all customer traffic. The
Gateway uses namespace selectors to allow `HTTPRoute` resources from namespaces labeled
`shared-gateway: "true"`. Benefits of this approach:
- One ELB instead of one per customer (significant cost saving)
- Centralized TLS configuration
- Single DNS target for all customer hostnames

**Why does the Envoy DaemonSet affect CiliumNetworkPolicy?**
Cilium Envoy runs with `hostNetwork: true` in `kube-system`. Host-network pods share the
node's network namespace, so Cilium classifies their traffic as the `cluster` entity
rather than a namespace-scoped endpoint identity. Standard `namespaceSelector` or
`ipBlock` selectors cannot match this traffic. Customer namespace network policies that
allow inbound traffic from the Gateway must use `fromEntities: [cluster]`.

See [Network Security](../security/network.md) for the full CiliumNetworkPolicy details.


## Hubble

**File:** `gitops/infrastructure/controllers/base/cilium/values.yaml`

```yaml
hubble:
  relay:
    enabled: true
  ui:
    enabled: true
```

Hubble is Cilium's observability layer. It captures network flow data from the eBPF
dataplane and makes it queryable.

- **Hubble Relay** aggregates flows from all nodes into a single gRPC endpoint
- **Hubble UI** provides a web interface for exploring flows, dropped packets, and policy
  decisions

**Accessing Hubble UI:**
```bash
cilium hubble ui
# or
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
```

Hubble is particularly useful for debugging CiliumNetworkPolicy: it shows exactly which
flows are allowed and which are dropped, and by which policy.


## Troubleshooting

```bash
# Check Cilium pod status
kubectl get pods -n kube-system -l k8s-app=cilium

# Check Cilium status on a specific node
kubectl exec -n kube-system <cilium-pod> -- cilium status

# List ENIs allocated by Cilium
kubectl exec -n kube-system <cilium-pod> -- cilium bpf endpoint list

# Check active network policies
kubectl exec -n kube-system <cilium-pod> -- cilium policy get

# Monitor live network flows (requires Hubble)
cilium hubble observe --namespace acme
```


## Future Work

- **FQDN egress policies:** Replace open `toEntities: [world]` egress rules with
  `toFQDNs` policies that restrict n8n and CNPG egress to specific AWS service hostnames.
- **Cilium network policies on infrastructure namespaces:** Add default-deny +
  explicit allow policies to `cert-manager`, `cnpg-system`, and `flux-system`.
- **WireGuard transparent encryption:** Enable `encryption.type: wireguard` in Cilium
  values to encrypt pod-to-pod traffic in transit within the VPC.
