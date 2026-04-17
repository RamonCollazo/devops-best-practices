# Monitoring and Observability

References:
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Grafana Loki](https://grafana.com/docs/loki/latest/)
- [Grafana Promtail](https://grafana.com/docs/loki/latest/send-data/promtail/)
- [AWS EKS Best Practices: Observability](https://docs.aws.amazon.com/eks/latest/best-practices/observability.html)


## Overview

The monitoring stack provides metrics and log aggregation for the entire cluster. It is
deployed in the `monitoring` namespace and managed by Flux through two dedicated
Kustomizations: `monitoring-controllers` and `monitoring-configs`.

### Components

| Component | Chart | What it does |
|-----------|-------|-------------|
| Prometheus | kube-prometheus-stack | Scrapes metrics from all cluster workloads |
| Grafana | kube-prometheus-stack | Unified dashboard UI for metrics and logs |
| Alertmanager | kube-prometheus-stack | Routes and deduplicates alerts |
| node-exporter | kube-prometheus-stack | Exposes node-level metrics (CPU, memory, disk) |
| kube-state-metrics | kube-prometheus-stack | Exposes Kubernetes object metrics (pod status, deployment replicas) |
| Loki | loki | Log aggregation backend |
| Promtail | promtail | Per-node log collector DaemonSet |


## Flux Reconciliation

```
infrastructure-configs
      |
      v
monitoring-controllers   (HelmReleases: kube-prometheus-stack, Loki, Promtail)
      |
      v
monitoring-configs       (Certificate, HTTPRoute for Grafana external access)
```

`monitoring-controllers` depends on `infrastructure-configs` so that the Gateway and
ClusterIssuer exist before the Grafana HTTPRoute and Certificate are applied.


## kube-prometheus-stack

**File:** `gitops/monitoring/controllers/base/kube-prometheus-stack/`

**Why kube-prometheus-stack instead of installing Prometheus and Grafana separately?**
kube-prometheus-stack is a curated Helm chart that bundles Prometheus, Grafana,
Alertmanager, node-exporter, and kube-state-metrics with pre-configured scrape rules,
recording rules, and dashboards for Kubernetes. Installing these separately requires
manually wiring up scrape configs, service monitors, and dashboards. The stack provides
production-ready defaults out of the box.

**Helm release naming:**
Flux names the Helm release as `{targetNamespace}-{HelmRelease.metadata.name}`, which
prefixes all generated service names with `monitoring-`. The Grafana service is
`monitoring-kube-prometheus-stack-grafana`, not `kube-prometheus-stack-grafana`. This
matters when configuring HTTPRoutes or internal service references.

**Grafana configuration:**

```yaml
grafana:
  additionalDataSources:
    - name: Loki
      type: loki
      url: http://monitoring-loki.monitoring.svc.cluster.local:3100
      access: proxy
  persistence:
    enabled: false
```

The Loki datasource is pre-configured so it is available immediately on first login.
`persistence: false` means Grafana state (dashboards, alert rules) is not stored in a
PVC, it is managed entirely through GitOps via ConfigMaps. Grafana is stateless; only
Prometheus and Alertmanager require persistent storage.

**Why 15d Prometheus retention on a 50 Gi volume?**
15 days covers two sprint cycles, providing enough history to correlate metrics with
deployment events and investigate recurring incidents. The 50 Gi volume is sized
conservatively for the current workload; Prometheus cardinality (number of unique
metric+label combinations) determines actual storage consumption. Monitor with
`prometheus_tsdb_storage_blocks_bytes` and resize if needed.

**Retrieving the Grafana admin password:**
```bash
kubectl get secret -n monitoring monitoring-kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
```


## Loki

**File:** `gitops/monitoring/controllers/base/loki/`

Loki is deployed in `SingleBinary` mode: a single pod that handles all Loki roles
(ingester, querier, distributor, compactor). This is appropriate for staging and
small-scale production where log volume is modest.

**Why SingleBinary instead of distributed/microservices mode?**
Distributed mode splits Loki into separate scalable components (ingesters, queriers,
distributors) that can be scaled independently. For this deployment, the operational
complexity of managing multiple components is not justified. SingleBinary mode is simpler,
requires fewer resources, and is the recommended starting point for Loki deployments
that do not require horizontal scaling.

**Why filesystem storage instead of S3?**
Loki supports multiple storage backends: filesystem (local disk), S3, GCS, Azure Blob.
Filesystem storage on a gp3-encrypted PVC is the simplest option for a single-node Loki
deployment. The tradeoff is that log data does not survive Loki pod or node loss. For
production, replace `storage.type: filesystem` with `s3` and configure an S3 bucket —
this also enables horizontal scaling if needed.

**Why `auth_enabled: false`?**
Multi-tenancy is disabled. With `auth_enabled: true`, every request to Loki must include
an `X-Scope-OrgID` header. In this single-tenant deployment (all workloads share one Loki
instance), disabling auth simplifies Promtail and Grafana configuration. If multi-tenant
log isolation is required in the future, enable auth and configure per-tenant labels.

**Why replication_factor: 1?**
SingleBinary mode with one replica does not support replication. A replication factor of 1
means log data is not replicated within Loki, consistent with the filesystem storage
choice.

**Loki service name:**
The Helm release is named `loki` in namespace `monitoring`, so Flux creates the service as
`monitoring-loki`. All internal references (Promtail push URL, Grafana datasource URL)
must use `http://monitoring-loki.monitoring.svc.cluster.local:3100`.


## Promtail

**File:** `gitops/monitoring/controllers/base/promtail/`

Promtail runs as a DaemonSet: one pod per node. It tails log files from
`/var/log/pods/` on the node filesystem and forwards them to Loki. Kubernetes labels
(namespace, pod name, container name, node name) are automatically attached as Loki
stream labels by the default Promtail pipeline.

**Why Promtail instead of Grafana Alloy?**
Grafana Alloy is the newer, more feature-rich collector that replaces Promtail in Grafana's
roadmap. For this deployment, Promtail is sufficient and simpler to configure. The only
required configuration is the Loki push URL:

```yaml
config:
  clients:
    - url: http://monitoring-loki.monitoring.svc.cluster.local:3100/loki/api/v1/push
```

Alloy would be the right choice if OpenTelemetry-native log collection, metric scraping,
or trace forwarding from the same agent is needed in the future.

**Why does Promtail need to know the Loki service name?**
The push URL must use the full Kubernetes service DNS name within the cluster. Loki does
not expose a fixed cluster-wide hostname, the service name is determined by the Helm
release name. Since Flux prefixes the release name with the target namespace, the service
is `monitoring-loki`, not `loki`.


## Exploring Logs in Grafana

1. Open Grafana → **Explore**
2. Select the **Loki** datasource in the top-left dropdown
3. Add a **Label filter**: `namespace` = `acme` (or any running namespace)
4. Click **Run query** or press Shift+Enter

Useful label filters:
- `namespace`: filter by Kubernetes namespace
- `pod`: filter by pod name
- `container`: filter by container name within a pod
- `node_name`: filter by node

**Why is service_name shown as "unknown service"?**
Loki v6 with schema v13 enables OTLP-based service detection by default. This populates
`service_name` from OpenTelemetry `service.name` resource attributes. Promtail does not
send OTLP metadata, so `service_name` shows as "unknown service". Use the `namespace`
or `pod` label instead, these are populated correctly by Promtail's Kubernetes
service discovery.


## Grafana External Access

**Files:** `gitops/monitoring/configs/base/grafana/`

Grafana is exposed externally through the shared Cilium Gateway:

```
https://grafana-staging.aws.raymondcollazo.com
  |
  v
HTTPRoute (monitoring-configs)
  |
  v
Service: monitoring-kube-prometheus-stack-grafana:80
```

The TLS certificate is issued by cert-manager via Let's Encrypt HTTP01 and stored in the
`shared-gateway` namespace (required because the Gateway reads secrets from its own
namespace).


## Future Work

- **Loki S3 storage:** Replace `storage.type: filesystem` with S3 for durability and
  horizontal scalability. Add an S3 bucket in `cloudformation/monitoring.yaml`.
- **Alertmanager routing:** Configure Alertmanager receivers (PagerDuty, Slack) and
  routing rules for critical alerts.
- **Grafana dashboards as code:** Add Grafana dashboard ConfigMaps to
  `monitoring-configs` for CNPG, n8n, and Cilium so dashboards are GitOps-managed.
- **Cilium FQDN egress for monitoring namespace:** Add CiliumNetworkPolicies to the
  `monitoring` namespace (currently unrestricted).
- **Promtail → Alloy migration:** Migrate to Grafana Alloy if OpenTelemetry-native
  collection is needed.
