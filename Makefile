PROJECT_NAME		?= devops-best-practices
ENVIRONMENT		?= staging
REGION			?= us-east-1

GITHUB_OWNER	?= RamonCollazo
GITHUB_REPO		?= devops-best-practices

GATEWAY_API_VERSION		?= v1.2.1
BARMAN_PLUGIN_VERSION	?= v0.11.0

# IAM principal that receives cluster-admin via an EKS Access Entry.
# Auto-converts assumed-role ARNs (SSO/CI) to IAM role ARNs, which is what
# EKS Access Entries require. Example conversion:
#   arn:aws:sts::123:assumed-role/MyRole/session -> arn:aws:iam::123:role/MyRole
# Override with: export ADMIN_ROLE_ARN=arn:aws:iam::<account>:role/<name>
ADMIN_ROLE_ARN		?= $(shell aws sts get-caller-identity --query 'Arn' --output text \
					| sed 's|arn:aws:sts::\([0-9]*\):assumed-role/\([^/]*\)/.*|arn:aws:iam::\1:role/\2|')

VPC_STACK			= $(PROJECT_NAME)-$(ENVIRONMENT)-vpc
EKS_STACK			= $(PROJECT_NAME)-$(ENVIRONMENT)-eks
NG_STACK			= $(PROJECT_NAME)-$(ENVIRONMENT)-nodegroup
IAM_STACK			= $(PROJECT_NAME)-$(ENVIRONMENT)-iam
S3_STACK			= $(PROJECT_NAME)-$(ENVIRONMENT)-s3

CLUSTER_NAME	= $(PROJECT_NAME)-$(ENVIRONMENT)

CFN_DIR				= provision/aws/cloudformation
HELM_DIR			= provision/aws/helm

# Fetched live from AWS - required for Cilium kube-proxy replacement
K8S_API_HOST	= $(shell aws eks describe-cluster \
					--name $(CLUSTER_NAME) \
					--region $(REGION) \
					--query 'cluster.endpoint' \
					--output text | sed 's|https://||')

.PHONY:	deploy-vpc deploy-eks deploy-nodegroup deploy-all deploy-iam deploy-s3 kubeconfig \
				delete-nodegroup delete-eks delete-vpc delete-iam delete-s3 delete-apps delete-infra \
				helm-repos install-gateway-api-crds install-cilium \
				install-cnpg install-barman-plugin install-controllers \
				flux-bootstrap create-cluster-vars \
				create-pod-identity-association create-cnpg-backup-association

# -- Deploy --

deploy-vpc:
	aws cloudformation deploy \
		--stack-name $(VPC_STACK) \
		--template-file $(CFN_DIR)/vpc.yaml \
		--parameter-overrides \
			ProjectName=$(PROJECT_NAME) \
			Environment=$(ENVIRONMENT) \
			ClusterName=$(CLUSTER_NAME) \
		--region $(REGION) \
		--no-fail-on-empty-changeset

deploy-eks: deploy-vpc
	aws cloudformation deploy \
		--stack-name $(EKS_STACK) \
		--template-file $(CFN_DIR)/eks.yaml \
		--parameter-overrides \
			ProjectName=$(PROJECT_NAME) \
			Environment=$(ENVIRONMENT) \
			VpcStackName=$(VPC_STACK) \
			AdminRoleArn=$(ADMIN_ROLE_ARN) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(REGION) \
		--no-fail-on-empty-changeset

deploy-nodegroup: deploy-eks
	aws cloudformation deploy \
		--stack-name $(NG_STACK) \
		--template-file $(CFN_DIR)/nodegroup.yaml \
		--parameter-overrides \
			ProjectName=$(PROJECT_NAME) \
			Environment=$(ENVIRONMENT) \
			VpcStackName=$(VPC_STACK) \
			EksStackName=$(EKS_STACK) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(REGION) \
		--no-fail-on-empty-changeset

deploy-s3:
	aws cloudformation deploy \
		--stack-name $(S3_STACK) \
		--template-file $(CFN_DIR)/s3.yaml \
		--parameter-overrides \
			ProjectName=$(PROJECT_NAME) \
			Environment=$(ENVIRONMENT) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(REGION) \
		--no-fail-on-empty-changeset

deploy-iam: deploy-eks
	aws cloudformation deploy \
		--stack-name $(IAM_STACK) \
		--template-file $(CFN_DIR)/iam.yaml \
		--parameter-overrides \
			ProjectName=$(PROJECT_NAME) \
			Environment=$(ENVIRONMENT) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(REGION) \
		--no-fail-on-empty-changeset

deploy-all: deploy-vpc deploy-eks deploy-nodegroup

# -- Kubeconfig --

kubeconfig:
	aws eks update-kubeconfig \
		--name $(CLUSTER_NAME) \
		--region $(REGION) \
		--kubeconfig ~/.kube/$(CLUSTER_NAME)-aws.yaml

# -- Delete (reverse order) --

delete-nodegroup:
	aws cloudformation delete-stack \
		--stack-name $(NG_STACK) \
		--region $(REGION)
	aws cloudformation wait stack-delete-complete \
		--stack-name $(NG_STACK) \
		--region $(REGION)

delete-eks:
	aws cloudformation delete-stack \
		--stack-name $(EKS_STACK) \
		--region $(REGION)
	aws cloudformation wait stack-delete-complete \
		--stack-name $(EKS_STACK) \
		--region $(REGION)

delete-vpc:
	aws cloudformation delete-stack \
		--stack-name $(VPC_STACK) \
		--region $(REGION)
	aws cloudformation wait stack-delete-complete \
		--stack-name $(VPC_STACK) \
		--region $(REGION)

delete-iam:
	aws cloudformation delete-stack \
		--stack-name $(IAM_STACK) \
		--region $(REGION)
	aws cloudformation wait stack-delete-complete \
		--stack-name $(IAM_STACK) \
		--region $(REGION)

# delete-s3 must run AFTER delete-iam (iam.yaml has no S3 import; safe to run after apps gone)
delete-s3:
	aws cloudformation delete-stack \
		--stack-name $(S3_STACK) \
		--region $(REGION)
	aws cloudformation wait stack-delete-complete \
		--stack-name $(S3_STACK) \
		--region $(REGION)

# -- Pod Identity Association --
# Links the SecretsReaderRole to the n8n ServiceAccount in a specific customer namespace.
# Run once per customer: make create-pod-identity-association NAMESPACE=acme
SECRETS_READER_ROLE_ARN = $(shell aws cloudformation describe-stacks \
	--stack-name $(IAM_STACK) \
	--region $(REGION) \
	--query 'Stacks[0].Outputs[?OutputKey==`SecretsReaderRoleArn`].OutputValue' \
	--output text)

create-pod-identity-association:
	aws eks create-pod-identity-association \
		--cluster-name $(CLUSTER_NAME) \
		--namespace $(NAMESPACE) \
		--service-account n8n \
		--role-arn $(SECRETS_READER_ROLE_ARN) \
		--region $(REGION)

# -- CNPG Backup Pod Identity Association --
# Links the CnpgBackupRole to the CNPG Cluster ServiceAccount (<namespace>-db) per customer.
# Run once per customer: make create-cnpg-backup-association NAMESPACE=acme
CNPG_BACKUP_ROLE_ARN = $(shell aws cloudformation describe-stacks \
	--stack-name $(S3_STACK) \
	--region $(REGION) \
	--query 'Stacks[0].Outputs[?OutputKey==`CnpgBackupRoleArn`].OutputValue' \
	--output text)

CNPG_BACKUP_BUCKET = $(shell aws cloudformation describe-stacks \
	--stack-name $(S3_STACK) \
	--region $(REGION) \
	--query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' \
	--output text)

create-cnpg-backup-association:
	aws eks create-pod-identity-association \
		--cluster-name $(CLUSTER_NAME) \
		--namespace $(NAMESPACE) \
		--service-account $(NAMESPACE)-db \
		--role-arn $(CNPG_BACKUP_ROLE_ARN) \
		--region $(REGION)

# -- Delete apps (run first) --
# Suspends the apps kustomization so Flux doesn't re-create resources while we delete them.
# Deletes CNPG clusters so the EBS CSI driver can release and delete the EBS volumes.

delete-apps:
	flux suspend kustomization apps
	kubectl delete clusters.postgresql.cnpg.io --all --all-namespaces --ignore-not-found
	kubectl wait --for=delete pvc --all --all-namespaces --timeout=180s || true

# -- Delete infrastructure (run after delete-apps, before delete-eks) --
# Suspends remaining Flux kustomizations and deletes the shared-gateway namespace.
# Deleting shared-gateway triggers the cloud controller manager to remove the Gateway ELB
# from AWS while the cluster is still alive. Without this, the ELB outlives the cluster
# and leaves dangling dependencies that block VPC deletion.

delete-infra:
	flux suspend kustomization infrastructure-configs
	flux suspend kustomization infrastructure-controllers
	kubectl delete namespace shared-gateway --ignore-not-found
	kubectl wait --for=delete namespace/shared-gateway --timeout=120s

# -- Helm repos --

helm-repos:
	helm repo add cilium https://helm.cilium.io/
	helm repo add jetstack https://charts.jetstack.io
	helm repo add cnpg https://cloudnative-pg.github.io/charts
	helm repo update

# -- Install controllers --
# Order: install-gateway-api-crds → cilium → deploy-nodegroup (manual) → cert-manager → cnpg

install-gateway-api-crds:
	kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VERSION)/standard-install.yaml
	kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=60s
	kubectl wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io --timeout=60s

install-cilium:
	# No --wait here - Cilium pods stay Pending until nodes join.
	# Run deploy-nodegroup next, then verify with: kubectl -n kube-system get pods
	helm upgrade --install cilium cilium/cilium \
		--namespace kube-system \
		--values $(HELM_DIR)/cilium-values.yaml \
		--set k8sServiceHost=$(K8S_API_HOST) \
		--set k8sServicePort=443

install-cnpg:
	helm upgrade --install cnpg cnpg/cloudnative-pg \
		--namespace cnpg-system \
		--create-namespace \
		--values $(HELM_DIR)/cnpg-values.yaml \
		--wait

# Installs the Barman Cloud plugin for CNPG (ObjectStore CRD + plugin sidecar).
# Must run after install-cnpg so cnpg-system namespace exists.
install-barman-plugin:
	kubectl apply -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/$(BARMAN_PLUGIN_VERSION)/manifest.yaml
	kubectl wait --for=condition=Established crd/objectstores.barmancloud.cnpg.io --timeout=60s

# NOTE: Run make deploy-nodegroup after install-cilium and before the rest.
# cert-manager is managed by Flux - do NOT install it manually.
# CSI driver and AWS provider are managed by Flux (not installed manually).
install-controllers: helm-repos install-gateway-api-crds install-cilium install-cnpg install-barman-plugin

# -- GitOps --
# Creates a ConfigMap in flux-system with cluster-specific values.
# Run this AFTER flux-bootstrap (flux-system namespace must exist first).
# Run after both deploy-eks and deploy-s3.
# Re-run any time cluster-vars needs updating (idempotent via --dry-run + apply).
create-cluster-vars:
	kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap cluster-vars \
		--namespace flux-system \
		--from-literal=k8sServiceHost=$(K8S_API_HOST) \
		--from-literal=cnpgBackupBucket=$(CNPG_BACKUP_BUCKET) \
		--dry-run=client -o yaml | kubectl apply -f -


# GITHUB_TOKEN must be set in the environment before running this target.
# export GITHUB_TOKEN=<your-pat>

flux-bootstrap:
	flux bootstrap github \
		--owner=$(GITHUB_OWNER) \
		--repository=$(GITHUB_REPO) \
		--branch=main \
		--path=clusters/aws/staging \
		--personal
