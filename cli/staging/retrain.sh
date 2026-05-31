#!/bin/bash
# Trigger full refetch and retrain

NAMESPACE="dota2metalab-staging"
S3_BUCKET="dota2metalab-models-643297135135"

echo "Deleting S3 model..."
aws s3 rm s3://$S3_BUCKET/models/current/dota2_model.h5
aws s3 rm s3://$S3_BUCKET/models/current/scaler.pkl

echo "Clearing MongoDB dataset versions..."
kubectl exec -it mongodb-0 -n $NAMESPACE -- mongosh --eval \
  "db.getSiblingDB('dota2metalab').dataset_versions.deleteMany({})"

echo "Clearing MongoDB matches..."
kubectl exec -it mongodb-0 -n $NAMESPACE -- mongosh --eval \
  "db.getSiblingDB('dota2metalab').matches.deleteMany({})"

echo "Deleting old jobs..."
kubectl delete job dota2metalab-fetcher -n $NAMESPACE --ignore-not-found
kubectl delete job dota2metalab-trainer -n $NAMESPACE --ignore-not-found

echo "Done! ArgoCD will self-heal and trigger fresh fetch + retrain."