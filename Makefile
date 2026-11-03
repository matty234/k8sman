KIND_CLUSTER ?= k8sman-dev
DEV_KUBECONFIG := $(CURDIR)/.kubeconfig-dev
# Kubeconfig the backend uses; override with `make backend KCFG=~/.kube/config`.
KCFG ?= $(DEV_KUBECONFIG)
export GOTOOLCHAIN := local

VERSION := $(shell sed -n 's/^version: *\([^+]*\).*/\1/p' frontend/pubspec.yaml)
RELEASE_APP := frontend/build/macos/Build/Products/Release/k8sman.app

.PHONY: backend backend-build backend-test frontend-test analyze test app app-dev cluster samples release icon clean-dist

backend-build:
	cd backend && go build -o bin/k8sman-server ./cmd/k8sman-server

## Run a standalone backend on 127.0.0.1:7443 (default: the dev kind cluster).
backend: backend-build
	./backend/bin/k8sman-server --kubeconfig $(KCFG)

backend-test:
	cd backend && go vet ./... && go test ./...

analyze:
	cd frontend && flutter analyze

frontend-test:
	cd frontend && flutter test

test: backend-test analyze frontend-test

## Run the macOS app. It builds, embeds and starts its own backend.
app:
	cd frontend && flutter run -d macos

## Run the macOS app against a separately started backend (`make backend`).
app-dev:
	cd frontend && flutter run -d macos --dart-define=K8SMAN_BACKEND=http://127.0.0.1:7443

## Build a Release .app (universal, with the embedded backend) and zip it to dist/.
release:
	cd frontend && flutter build macos --release
	test -x "$(RELEASE_APP)/Contents/MacOS/k8sman-server"
	codesign --verify --deep --strict "$(RELEASE_APP)" || codesign --force --deep --sign - "$(RELEASE_APP)"
	mkdir -p dist
	rm -f dist/k8sman-$(VERSION)-macos.zip
	ditto -c -k --sequesterRsrc --keepParent "$(RELEASE_APP)" dist/k8sman-$(VERSION)-macos.zip
	@echo "dist/k8sman-$(VERSION)-macos.zip"

## Regenerate the app icon PNGs (tools/app_icon).
icon:
	cd tools/app_icon && flutter test

clean-dist:
	rm -rf dist

## Create the dev kind cluster and load sample workloads.
cluster:
	kind create cluster --name $(KIND_CLUSTER) --kubeconfig $(DEV_KUBECONFIG)
	$(MAKE) samples

samples:
	KUBECONFIG=$(DEV_KUBECONFIG) kubectl apply -f dev/samples.yaml
	KUBECONFIG=$(DEV_KUBECONFIG) kubectl wait --for=condition=Established crd/widgets.example.k8sman.dev --timeout=60s
	KUBECONFIG=$(DEV_KUBECONFIG) kubectl apply -f dev/widgets.yaml
