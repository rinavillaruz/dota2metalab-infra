#!/bin/bash

set -euo pipefail

trap 'echo "❌ Error on line $LINENO - teardown failed"' ERR
trap 'echo "👋 Teardown script finished"' EXIT

confirm() {
    local message=$1
    local action=$2
    echo "⚠️  $message (y/n)"
    read -r answer
    if [ "$answer" == "y" ]; then
        $action
    else
        echo "⏭️  Skipped."
    fi
}

delete_argocd() {
    echo "🗑️  Deleting ArgoCD..."
    helm uninstall argocd --namespace argocd 2>/dev/null || echo "ArgoCD not found, skipping..."

    # Delete CRDs that helm keeps — no waiting
    kubectl delete crd \
        applications.argoproj.io \
        applicationsets.argoproj.io \
        appprojects.argoproj.io \
        --wait=false \
        2>/dev/null || echo "CRDs not found, skipping..."

    echo "✅ ArgoCD uninstalled! Cluster deletion will clean up the rest."
}

delete_cluster() {
    echo "🗑️  Deleting cluster..."
    kind delete cluster --name dota2metalab 2>/dev/null || echo "Cluster not found, skipping..."
    echo "⏳ Waiting for cluster to be fully deleted..."
    count=0
    while kind get clusters | grep dota2metalab &>/dev/null; do
        count=$((count + 1))
        echo "${count}s - still deleting..."
        sleep 1
    done
    echo "✅ Cluster deleted! after ${count}s!"
}

confirm "Delete ArgoCD?" delete_argocd
confirm "Delete the dota2metalab Kind cluster?" delete_cluster