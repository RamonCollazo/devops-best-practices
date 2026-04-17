# Infrastructure Security

References:
- [AWS EKS Best Practices: Protecting the Infrastructure](https://docs.aws.amazon.com/eks/latest/best-practices/protecting-the-infrastructure.html)
- [AWS EKS Best Practices: Auditing and Logging](https://docs.aws.amazon.com/eks/latest/best-practices/auditing-and-logging.html)

See [best-practices-traceability.md](best-practices-traceability.md) for a table mapping every best practice to the exact file and config.


## Implemented Practices

### 1. Bottlerocket as the Worker Node OS

**File:** `provision/aws/cloudformation/nodegroup.yaml`

```yaml
AmiType: BOTTLEROCKET_x86_64
```

**What it does:**
Replaces AL2023 with Bottlerocket, a purpose-built container OS from AWS. Key properties:

- **Read-only OS partition** - the root filesystem is mounted read-only; an attacker who
  gains node access cannot modify OS binaries or configuration
- **dm-verity verified boot** - the disk image is cryptographically verified at boot;
  tampering is detected before the OS starts
- **SELinux enforced by default** - mandatory access controls restrict what containers and
  processes can do on the host even when running as root
- **No package manager or general-purpose shell** - there is no `apt`, `yum`, or `/bin/bash`
  on the host; the attack surface is drastically smaller than a general-purpose Linux
  distribution
- **Automated OS updates via node replacement** - Bottlerocket is designed to be updated
  by replacing nodes (immutable infrastructure), not in-place package upgrades

**Why:**
The AWS EKS best practices guide recommends using a container-optimized OS for worker
nodes. Bottlerocket directly addresses the most common host-level attack vectors: host
filesystem modification, package installation for persistence, and lateral movement via
OS tools. It enforces the immutable infrastructure principle at the OS level.

The change from `AL2023_x86_64_STANDARD` to `BOTTLEROCKET_x86_64` is a single field in
CloudFormation. EKS manages the AMI version through the managed node group lifecycle -
node replacement on updates is handled by `UpdateConfig.MaxUnavailable: 1`.


### 2. SSM Session Manager for Node Access

**File:** `provision/aws/cloudformation/nodegroup.yaml`

```yaml
ManagedPolicyArns:
  - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

**What it does:**
Attaches the `AmazonSSMManagedInstanceCore` managed policy to the node IAM role. This
enables AWS Systems Manager Session Manager to open a shell session into the Bottlerocket
admin container without SSH keys, open ports, or a bastion host.

To access a node:
```bash
aws ssm start-session --target <instance-id> --region <region>
```

**Why:**
SSH key management is a persistent operational burden and a common attack vector: leaked
keys, forgotten authorized_keys entries, and key rotation failures all create long-lived
access credentials. SSM Session Manager eliminates this entirely:

- No inbound ports required on the node security group (no port 22)
- Access is controlled by IAM policies, not key files on disk
- Every session is logged to CloudTrail; shell output can be streamed to CloudWatch Logs
- Access can be granted or revoked instantly by updating IAM policies

With Bottlerocket, SSM connects into the admin container, which provides a privileged
shell into the host. This is the only supported method for interactive node access on
Bottlerocket; there is no SSH daemon to configure.


### 3. Workers on Private Subnets

**File:** `provision/aws/cloudformation/nodegroup.yaml`

```yaml
Subnets:
  - Fn::ImportValue: !Sub '${VpcStackName}-PrivateSubnet1Id'
  - Fn::ImportValue: !Sub '${VpcStackName}-PrivateSubnet2Id'
  - Fn::ImportValue: !Sub '${VpcStackName}-PrivateSubnet3Id'
```

**What it does:**
All worker nodes are placed in private subnets with no direct route to the internet.
Outbound internet access goes through NAT Gateways. Inbound connections from the internet
cannot reach the nodes directly.

**Why:**
Nodes on public subnets are directly reachable from the internet on any port. Even with
security groups, direct internet exposure is unnecessary and increases attack surface. NAT
Gateways allow nodes to pull container images and call AWS APIs while remaining
unreachable from the public internet.


### 4. Immutable Infrastructure (Node Replacement over In-Place Upgrades)

**File:** `provision/aws/cloudformation/nodegroup.yaml`

```yaml
UpdateConfig:
  MaxUnavailable: 1
```

**What it does:**
EKS managed node group updates replace nodes one at a time rather than upgrading in place.
When a new AMI version is available (Bottlerocket update or EKS version upgrade), the node
group performs a rolling replacement: one node is cordoned, drained, terminated, and
replaced with a new node running the updated image.

**Why:**
In-place OS upgrades accumulate configuration drift over time. A node that has been
upgraded multiple times in place may have a different effective configuration than a freshly
provisioned node from the same AMI. Node replacement guarantees that every running node
matches the current AMI definition exactly. Combined with Bottlerocket's read-only OS
partition, there is no mechanism for untracked changes to accumulate on a node.


## Not Implemented (Noted for Awareness)

- **Amazon Inspector:** An account-level service that scans EC2 instances for CVEs and
  network exposure. Enable via `aws inspector2 enable --resource-types EC2 --region <region>`.
  SSM agent must be installed (Bottlerocket includes it). Not represented as a file in this
  repo since it is an account-level toggle, not a cluster resource.

- **CIS Benchmark (kube-bench):** Run `kube-bench` against the cluster after deployment to
  verify compliance with the CIS Amazon EKS Benchmark. This is a post-deployment audit
  step, not a static configuration.

- **SELinux custom policies:** Bottlerocket enforces SELinux in enforcing mode by default.
  Custom MCS labels per pod (`seLinuxOptions.level`) can be added to the pod security
  context for stricter isolation between pods sharing a node.
