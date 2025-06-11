#!/bin/bash

set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <username>"
  exit 1
fi

USER=$1
NAMESPACE="ns-$USER"
CSR_NAME=$USER
KUBECONFIG_FILE="${USER}.kubeconfig"

echo "[1] Creating namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "[2] Generating key and CSR for $USER"
openssl genrsa -out "${USER}.key" 2048
openssl req -new -key "${USER}.key" -out "${USER}.csr" -subj "/CN=${USER}"

echo "[3] Base64 encode CSR and prepare Kubernetes CSR manifest"
ENCODED_CSR=$(base64 < "${USER}.csr" | tr -d '\n')

cat <<EOF > "${USER}-csr.yaml"
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${CSR_NAME}
spec:
  request: ${ENCODED_CSR}
  signerName: kubernetes.io/kube-apiserver-client
  usages:
  - client auth
EOF

echo "[4] Applying and approving CSR"
kubectl apply -f "${USER}-csr.yaml"
kubectl certificate approve "${CSR_NAME}"

echo "[5] Fetching and saving the certificate"
kubectl get csr "${CSR_NAME}" -o jsonpath='{.status.certificate}' | base64 -d > "${USER}.crt"

echo "[6] Creating kubeconfig for ${USER}"
kubectl config set-credentials "${USER}" \
  --client-key="${USER}.key" \
  --client-certificate="${USER}.crt" \
  --embed-certs=true

kubectl config set-context "${USER}" \
  --cluster="$(kubectl config view -o jsonpath='{.clusters[0].name}')" \
  --user="${USER}" \
  --namespace="${NAMESPACE}"

kubectl config view --minify --flatten --context="${USER}" > "${KUBECONFIG_FILE}"

echo "[7] Creating Role and RoleBinding for namespace ${NAMESPACE}"

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${USER}-admin
  namespace: ${NAMESPACE}
rules:
- apiGroups: ["", "apps", "batch", "rbac.authorization.k8s.io", "kubeflow.org"]
  resources: ["*"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${USER}-admin-binding
  namespace: ${NAMESPACE}
subjects:
- kind: User
  name: ${USER}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: ${USER}-admin
  apiGroup: rbac.authorization.k8s.io
EOF

echo "[8] Cleaning up local kubeconfig context and user"
kubectl config unset users."${USER}"
kubectl config unset contexts."${USER}"
rm -f ${USER}.crt ${USER}.csr ${USER}.key ${USER}-csr.yaml 


echo "Done. Kubeconfig written to ${KUBECONFIG_FILE}"
