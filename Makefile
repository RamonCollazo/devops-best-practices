PROJECT_NAME	?= devops-best-practice-staging
ENVIRONMENT		?= staging
REGION				?= us-east-1

GITHUB_OWNER	?= RamonCollazo
GITHUB_REPO		?= devops-best-practices

VPC_STACK			= $(PROJECT_NAME)-$(ENVIRONMENT)-vpc
EKS_STACK			= $(PROJECT_NAME)-$(ENVIRONMENT)-eks
NG_STACK			= $(PROJECT_NAME)-$(ENVIRONMENT)-nodegroup

CLUSTER_NAME	= $(PROJECT_NAME)-$(ENVIRONMENT)

CFN_DIR				= provision/aws/cloudformation
HELM_DIR			= provision/aws/helm

# Fetched live from AWS — required for Cilium kube-proxy replacement
K8S_API_HOST	= $(shell aws eks describe-cluster \
					--name $(CLUSTER_NAME) \
					--region $(REGION) \
					--query 'cluster.endpoint' \
					--output text | sed 's|https://||')

.PHONY:	deploy-vpc deploy-eks deploy-nodegroup deploy-all kubeconfig \
				delete-nodegroup delete-eks delete-vpc \
				helm-repos install-cilium install-cert-manager \
				install-external-secrets install-cnpg install-controllers \
				flux-bootstrap create-cluster-vars

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

# -- Helm repos --

helm-repos:
	helm repo add cilium https://helm.cilium.io/
	helm repo add jetstack https://charts.jetstack.io
	helm repo add external-secrets https://charts.external-secrets.io
	helm repo add cnpg https://cloudnative-pg.github.io/charts
	helm repo update

# -- Install controllers --
# Order: cilium → deploy-nodegroup (manual) → cert-manager → external-secrets → cnpg

install-cilium:
	kubectl delete daemonset aws-node -n kube-system --ignore-not-found
	kubectl delete daemonset kube-proxy -n kube-system --ignore-not-found
	# No --wait here — Cilium pods stay Pending until nodes join.
	# Run deploy-nodegroup next, then verify with: kubectl -n kube-system get pods
	helm upgrade --install cilium cilium/cilium \
		--namespace kube-system \
		--values $(HELM_DIR)/cilium-values.yaml \
		--set k8sServiceHost=$(K8S_API_HOST) \
		--set k8sServicePort=443

install-cert-manager:
	helm upgrade --install cert-manager jetstack/cert-manager \
		--namespace cert-manager \
		--create-namespace \
		--values $(HELM_DIR)/cert-manager-values.yaml \
		--wait

install-external-secrets:
	helm upgrade --install external-secrets external-secrets/external-secrets \
		--namespace external-secrets \
		--create-namespace \
		--values $(HELM_DIR)/external-secrets-values.yaml \
		--wait

install-cnpg:
	helm upgrade --install cnpg cnpg/cloudnative-pg \
		--namespace cnpg-system \
		--create-namespace \
		--values $(HELM_DIR)/cnpg-values.yaml \
		--wait

# NOTE: Run make deploy-nodegroup after install-cilium and before the rest.
install-controllers: helm-repos install-cilium install-cert-manager \
					install-external-secrets install-cnpg

# -- GitOps --
# Creates a ConfigMap in flux-system with cluster-specific values.
# Run this after deploy-eks and kubeconfig, before flux-bootstrap.
create-cluster-vars:
	kubectl create configmap cluster-vars \
		--namespace flux-system \
		--from-literal=k8sServiceHost=$(K8S_API_HOST) \
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
