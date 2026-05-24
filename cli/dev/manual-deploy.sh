#!/bin/bash

set -euo pipefail

trap 'echo "Error on line $LINENO - deployment failed"' ERR
trap 'echo "👋 Deploy script finished"' EXIT

# Variables
RELEASE_NAME="dota2metalab"
NAMESPACE="dota2metalab"
CHART_PATH="deploy/helm"
IMAGE_TAG="${1:-latest}" #use first argument or deploy to latest
ENV="${2:-dev}" 

function check_dependencies() {
    echo "Checking dependencies..."

    if ! command -v kubectl &> /dev/null; then
        echo "Error: kubectl not installed"
        exit 1
    fi

    if ! command -v helm &> /dev/null; then
        echo "Error: helm not installed"
        exit 1
    fi

    echo "All dependencies found!"
}

check_dependencies

if [ "$ENV" == 'dev' ]; then
    VALUES_FILE='deploy/helm/values-dev.yaml'
    NAMESPACE="dota2metalab-dev"
elif [ "$ENV" == 'prod' ]; then
    VALUES_FILE='deploy/helm/values-prod.yaml'
    NAMESPACE="dota2metalab-prod"
else
    echo "Error: unknown environment $ENV"
    exit 1
fi

echo "Deploying $RELEASE_NAME to namespace $NAMESPACE..."
echo "Image Tag: $IMAGE_TAG"

# Deploy with Helm
helm upgrade --install $RELEASE_NAME $CHART_PATH  -f $VALUES_FILE \
    --namespace $NAMESPACE \
    --create-namespace \
    --set image.tag=$IMAGE_TAG \
    --debug

echo "Deployment Complete!"