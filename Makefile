KIND_CLUSTER ?= k8sman-dev
DEV_KUBECONFIG := $(CURDIR)/.kubeconfig-dev
# Kubeconfig the backend uses; override with `make backend KCFG=~/.kube/config`.
KCFG ?= $(DEV_KUBECONFIG)
export GOTOOLCHAIN := local

.PHONY: backend backend-build backend-test frontend-test analyze test app cluster samples

backend-build:
	cd backend && go build -o bin/k8sman-server ./cmd/k8sman-server

## Run the backend (default: the dev kind cluster).
backend: backend-build
	./backend/bin/k8sman-server --kubeconfig $(KCFG)

backend-test:
	cd backend && go vet ./... && go test ./...

analyze:
	cd frontend && flutter analyze

frontend-test:
	cd frontend && flutter test

test: backend-test analyze frontend-test

## Run the macOS app (start `make backend` first).
app:
	cd frontend && flutter run -d macos

## Create the dev kind cluster and load sample workloads.
cluster:
	kind create cluster --name $(KIND_CLUSTER) --kubeconfig $(DEV_KUBECONFIG)
	$(MAKE) samples

samples:
	KUBECONFIG=$(DEV_KUBECONFIG) kubectl apply -f dev/samples.yaml
	KUBECONFIG=$(DEV_KUBECONFIG) kubectl wait --for=condition=Established crd/widgets.example.k8sman.dev --timeout=60s
	KUBECONFIG=$(DEV_KUBECONFIG) kubectl apply -f dev/widgets.yaml
