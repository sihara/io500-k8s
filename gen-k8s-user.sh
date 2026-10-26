#!/bin/bash
# Create a namespace, a ServiceAccount and a namespace-scoped Role for an IO500 benchmark user,
# and write a kubeconfig with a short-lived token.
# Usage: ./gen-k8s-user.sh <username> [token-duration, default 168h]
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <username> [token-duration]"
  exit 1
fi

USER=$1
DURATION=${2:-168h}
NAMESPACE="ns-$USER"
KUBECONFIG_FILE="${USER}.kubeconfig"

echo "[1] Creating namespace $NAMESPACE and ServiceAccount $USER"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" create serviceaccount "$USER" --dry-run=client -o yaml | kubectl apply -f -

echo "[2] Creating Role and RoleBinding (namespace only, no RBAC changes)"
cat <<YAML | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${USER}-admin
  namespace: ${NAMESPACE}
rules:
- apiGroups: ["", "apps", "batch", "kubeflow.org"]
  resources: ["*"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${USER}-admin-binding
  namespace: ${NAMESPACE}
subjects:
- kind: ServiceAccount
  name: ${USER}
  namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: ${USER}-admin
  apiGroup: rbac.authorization.k8s.io
YAML

echo "[3] Issuing a token valid for ${DURATION}"
TOKEN=$(kubectl -n "$NAMESPACE" create token "$USER" --duration="$DURATION")

echo "[4] Writing ${KUBECONFIG_FILE}"
CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
umask 077
cat > "$KUBECONFIG_FILE" <<CFG
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER}
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA}
users:
- name: ${USER}
  user:
    token: ${TOKEN}
contexts:
- name: ${USER}
  context:
    cluster: ${CLUSTER}
    user: ${USER}
    namespace: ${NAMESPACE}
current-context: ${USER}
CFG

echo "Done. ${KUBECONFIG_FILE} written (mode 600, token expires in ${DURATION}). Do not commit it."
echo "Revoke: kubectl -n ${NAMESPACE} delete serviceaccount ${USER}"
