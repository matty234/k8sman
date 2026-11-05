KIND_CLUSTER ?= k8sman-dev
DEV_KUBECONFIG := $(CURDIR)/.kubeconfig-dev
# Kubeconfig the backend uses; override with `make backend KCFG=~/.kube/config`.
KCFG ?= $(DEV_KUBECONFIG)
export GOTOOLCHAIN := local

VERSION := $(shell sed -n 's/^version: *\([^+]*\).*/\1/p' frontend/pubspec.yaml)
RELEASE_APP := frontend/build/macos/Build/Products/Release/k8sman.app
RELEASE_ZIP := dist/k8sman-$(VERSION)-macos.zip
RELEASE_DMG := dist/k8sman-$(VERSION)-macos.dmg

# Updates (docs/UPDATES.md). SPARKLE_PUBLIC_ED_KEY overrides the key in
# frontend/macos/Runner/Configs/AppInfo.xcconfig; REQUIRE_UPDATE_KEY=1 makes a
# release without one an error (CI). The private key for `make appcast` comes
# from SPARKLE_ED_KEY_FILE, $$SPARKLE_PRIVATE_ED_KEY or the login keychain.
SPARKLE_PUBLIC_ED_KEY ?=
REQUIRE_UPDATE_KEY ?=
SPARKLE_ED_KEY_FILE ?=
GITHUB_REPO ?= matty234/k8sman
RELEASE_URL ?= https://github.com/$(GITHUB_REPO)/releases/tag/v$(VERSION)
DOWNLOAD_URL ?= https://github.com/$(GITHUB_REPO)/releases/download/v$(VERSION)/k8sman-$(VERSION)-macos.zip
RELEASE_NOTES ?=

# Developer ID signing and notarization (docs/UPDATES.md). With
# MACOS_SIGN_IDENTITY set, `make release` signs with it (hardened runtime);
# NOTARIZE=1 also notarizes and staples, using NOTARY_KEY_FILE, NOTARY_KEY_ID
# and NOTARY_ISSUER_ID (an App Store Connect API key). Without an identity
# the app is ad-hoc signed, as before.
MACOS_SIGN_IDENTITY ?=
MACOS_KEYCHAIN ?=
NOTARIZE ?=

.PHONY: backend backend-build backend-test frontend-test analyze test app app-dev cluster samples release appcast sparkle-tools update-e2e icon shots clean-dist

backend-build:
	cd backend && go build -o bin/k8sman-server ./cmd/k8sman-server

## Run a standalone backend on 127.0.0.1:7443 (default: the dev kind cluster).
## Unless K8SMAN_AUTH_TOKEN is set it generates a bearer token, prints it on
## stderr and writes it to ~/.config/k8sman/dev-token (0600) for app-dev/curl.
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
## The app reads the backend's token from ~/.config/k8sman/dev-token, or
## K8SMAN_TOKEN=… (passed as --dart-define) overrides it.
K8SMAN_TOKEN ?=
app-dev:
	cd frontend && flutter run -d macos --dart-define=K8SMAN_BACKEND=http://127.0.0.1:7443 $(if $(K8SMAN_TOKEN),--dart-define=K8SMAN_TOKEN=$(K8SMAN_TOKEN))

## Build a Release .app (universal, with the embedded backend and Sparkle),
## sign it (Developer ID + notarization when configured, else ad-hoc), zip it to dist/ (plus a
## signed, notarized .dmg with a Developer ID) and write dist/SHA256SUMS. CFBundleVersion is set to the
## version, which is what Sparkle compares.
release:
	cd frontend && flutter build macos --release --build-name=$(VERSION) --build-number=$(VERSION)
	test -x "$(RELEASE_APP)/Contents/MacOS/k8sman-server"
	test -d "$(RELEASE_APP)/Contents/Frameworks/Sparkle.framework"
	@if [ -n "$(SPARKLE_PUBLIC_ED_KEY)" ]; then \
	  plutil -replace SUPublicEDKey -string "$(SPARKLE_PUBLIC_ED_KEY)" "$(RELEASE_APP)/Contents/Info.plist" && \
	  codesign --force --deep --sign - "$(RELEASE_APP)"; \
	fi
	@key="$$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$(RELEASE_APP)/Contents/Info.plist" 2>/dev/null)"; \
	if [ -z "$$key" ]; then \
	  if [ -n "$(REQUIRE_UPDATE_KEY)" ]; then echo "error: no SUPublicEDKey; set SPARKLE_PUBLIC_ED_KEY (docs/UPDATES.md)" >&2; exit 1; fi; \
	  echo "warning: no SUPublicEDKey, so in-app updates are disabled in this build (docs/UPDATES.md)" >&2; \
	fi
ifneq ($(MACOS_SIGN_IDENTITY),)
	tools/sign-macos.sh "$(RELEASE_APP)" "$(MACOS_SIGN_IDENTITY)" $(MACOS_KEYCHAIN)
ifneq ($(NOTARIZE),)
	tools/notarize-macos.sh "$(RELEASE_APP)"
endif
else
	codesign --verify --deep --strict "$(RELEASE_APP)" || codesign --force --deep --sign - "$(RELEASE_APP)"
endif
	mkdir -p dist
	rm -f $(RELEASE_ZIP)
	ditto -c -k --sequesterRsrc --keepParent "$(RELEASE_APP)" $(RELEASE_ZIP)
	rm -f $(RELEASE_DMG)
ifneq ($(MACOS_SIGN_IDENTITY),)
	tools/make-dmg.sh "$(RELEASE_APP)" $(RELEASE_DMG) "$(MACOS_SIGN_IDENTITY)" $(MACOS_KEYCHAIN)
ifneq ($(NOTARIZE),)
	tools/notarize-macos.sh $(RELEASE_DMG)
endif
endif
	cd dist && shasum -a 256 k8sman-$(VERSION)-macos.zip $(if $(MACOS_SIGN_IDENTITY),k8sman-$(VERSION)-macos.dmg) > SHA256SUMS
	@echo "$(RELEASE_ZIP)"

## Fetch Sparkle's signing tools (pinned by SHA-256) into build/sparkle.
sparkle-tools:
	tools/sparkle-tools.sh

## EdDSA-sign the release zip and write the signed feed dist/appcast.xml.
appcast: sparkle-tools
	@test -f $(RELEASE_ZIP) || { echo "error: $(RELEASE_ZIP) missing; run make release first" >&2; exit 1; }
	python3 tools/appcast.py --zip $(RELEASE_ZIP) --version $(VERSION) \
	  --download-url "$(DOWNLOAD_URL)" --release-url "$(RELEASE_URL)" \
	  $(if $(RELEASE_NOTES),--notes "$(RELEASE_NOTES)") \
	  $(if $(SPARKLE_ED_KEY_FILE),--ed-key-file "$(SPARKLE_ED_KEY_FILE)") \
	  --sparkle-bin build/sparkle/bin --out dist/appcast.xml
	cd dist && shasum -a 256 k8sman-$(VERSION)-macos.zip $$(ls k8sman-$(VERSION)-macos.dmg 2>/dev/null) appcast.xml > SHA256SUMS

## Local end-to-end update test: two versions, a local feed, Sparkle's
## installer, and tampered-archive checks. No GitHub. See docs/UPDATES.md.
update-e2e:
	tools/update-e2e.sh

## Regenerate the app icon PNGs (tools/app_icon).
icon:
	cd tools/app_icon && flutter test

## Render the README screenshots into docs/images (demo data; tools/marketing-shots.sh).
shots:
	tools/marketing-shots.sh

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
