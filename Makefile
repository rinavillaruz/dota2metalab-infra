.PHONY: dev-up dev-down

dev-up:
	@echo "Creating Kind Cluster..."
	@kind create cluster --name dota2metalab --config infrastructure/kind/cluster.yaml 2>/dev/null || echo "⚠️  Cluster already exists, skipping creation..."
	@echo "Cluster created!"
	@./cli/dev/setup-cicd.sh

dev-down:
	@./cli/dev/destroy-cluster.sh

sync:
	@git pull origin dev --rebase