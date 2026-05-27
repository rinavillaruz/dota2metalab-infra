#!/bin/bash

# Navigate to repo root regardless of where script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."

# Step -1 — Ensure Kind cluster is running
echo "🔍 Checking Kind cluster..."
if ! kind get clusters 2>/dev/null | grep -q "kind"; then
    echo "🚀 No Kind cluster found, creating..."
    kind create cluster --config infrastructure/kind/cluster.yaml
    echo "✅ Kind cluster created!"
else
    echo "✅ Kind cluster already running!"
fi

echo "🚀 Starting ArgoCD deployment..."

# Step 0 — Cleanup any existing ArgoCD
echo "🧹 Step 0: Cleaning up any existing ArgoCD..."
helm uninstall argocd --namespace argocd 2>/dev/null || true

for crd in applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io; do
    kubectl get "$crd" --all-namespaces -o json 2>/dev/null | \
        jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
        while read ns name; do
            kubectl patch "$crd" "$name" -n "$ns" \
                --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
        done
    kubectl delete crd "$crd" --wait=true 2>/dev/null || true
done

kubectl delete namespace argocd --ignore-not-found --wait=true 2>/dev/null || true
until ! kubectl get namespace argocd &>/dev/null; do
    echo "  waiting for argocd namespace to terminate..."
    sleep 2
done
echo "✅ Cleanup done!"

# Step 1 — Install ArgoCD via Helm
ARGOCD_CHART_VERSION="9.5.11"
echo "🚀 Step 1: Installing ArgoCD chart ${ARGOCD_CHART_VERSION}..."
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version ${ARGOCD_CHART_VERSION} \
  -f deploy/argocd/values.yaml &

HELM_PID=$!
count=0
while kill -0 $HELM_PID &>/dev/null; do
    count=$((count + 1))
    echo "  ${count}s - installing..."
    sleep 1
done
wait $HELM_PID
echo "✅ ArgoCD installed after ${count}s!"

# Step 2 — Wait for all pods to be ready
echo "⏳ Step 2: Waiting for ArgoCD pods to be ready..."
count=0
while ! kubectl wait --for=condition=Ready pods --all -n argocd --timeout=5s &>/dev/null; do
    count=$((count + 1))
    echo "  ${count}s - waiting..."
    sleep 1
done
echo "✅ ArgoCD pods ready after ${count}s!"

# Step 3 — Apply ArgoCD app
echo "⏳ Step 3: Applying ArgoCD app..."
kubectl apply -f argocd-apps/dota2-dev.yaml 2>/dev/null
echo "✅ ArgoCD app applied!"

echo ""
echo "Admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d
echo ""
echo "ArgoCD UI: http://localhost:8080"
echo ""

# Step 4 — Port forward (blocking)
echo "🚀 Step 4: Starting port-forward on http://localhost:8080 (Ctrl+C to stop)..."

echo "⏳ Waiting for ArgoCD server to be fully ready..."
kubectl wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=argocd-server \
    -n argocd \
    --timeout=120s
echo "✅ ArgoCD server ready!"

sleep 5
kubectl port-forward svc/argocd-server -n argocd 8080:80 || true