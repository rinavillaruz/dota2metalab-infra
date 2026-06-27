#!/bin/bash
set -e

echo "Getting ArgoCD password..."
ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d)

echo ARGOCD_PASSWORD

echo "Logging in..."
argocd login argocd.dota2metalab.com \
  --username admin \
  --password $ARGOCD_PASSWORD \
  --insecure --grpc-web

echo "Syncing staging..."
argocd app sync dota2-staging --force
argocd app wait dota2-staging --health --timeout 600

echo "Syncing prod..."
argocd app sync dota2-prod --force
argocd app wait dota2-prod --health --timeout 600

echo "Done!"
curl https://dota2metalab.com/health