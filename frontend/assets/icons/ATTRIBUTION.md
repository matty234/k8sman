# Bundled CRD group icons

These icons identify the projects whose custom resources k8sman shows. They are
used only to label those projects' resources (nominative use); no endorsement
by the projects, the CNCF or the Linux Foundation is implied. All marks belong
to their owners.

Each file was downloaded on 2026-11-03, cropped to its visible content, padded
square and downscaled to 128×128 PNG. The group → icon mapping lives in
`lib/ui/widgets/group_icon.dart` and `backend/internal/icons/curated.go`.

## CNCF artwork

Source: <https://github.com/cncf/artwork> (`projects/<project>/icon/color/`).
Licence: the repository's [LICENSE.md](https://github.com/cncf/artwork/blob/main/LICENSE.md)
makes all its artwork available under the
[Linux Foundation trademark usage guidelines](https://www.linuxfoundation.org/trademark-usage/).
That is a trademark policy, not an open-source licence such as Apache-2.0 or CC-BY.

| File | Project | Source path | API groups |
|---|---|---|---|
| argo.png | Argo | `projects/argo/icon/color/argo-icon-color.png` | `argoproj.io` |
| cert-manager.png | cert-manager | `projects/cert-manager/icon/color/cert-manager-icon-color.png` | `cert-manager.io`, `*.cert-manager.io` |
| cilium.png | Cilium | `projects/cilium/icon/color/cilium_icon-color.png` | `cilium.io`, `*.cilium.io` |
| cloudnativepg.png | CloudNativePG | `projects/cloudnativepg/icon/color/cloudnativepg-icon-color.png` | `*.cnpg.io` |
| contour.png | Contour | `projects/contour/icon/color/contour-icon-color.png` | `projectcontour.io` |
| crossplane.png | Crossplane | `projects/crossplane/icon/color/crossplane-icon-color.png` | `*.crossplane.io` |
| dapr.png | Dapr | `projects/dapr/icon/color/dapr-icon-color.png` | `*.dapr.io` |
| envoy.png | Envoy / Envoy Gateway | `projects/envoy/icon/color/envoy-icon-color.png` | `*.envoyproxy.io` |
| external-secrets.png | External Secrets Operator | `projects/external-secrets-operator/icon/color/eso-icon-color.png` | `*.external-secrets.io` |
| flux.png | Flux | `projects/flux/icon/color/flux-icon-color.png` | `*.fluxcd.io` |
| harbor.png | Harbor | `projects/harbor/icon/color/harbor-icon-color.png` | `*.goharbor.io` |
| istio.png | Istio | `projects/istio/icon/color/istio-icon-color.png` | `*.istio.io` |
| jaeger.png | Jaeger | `projects/jaeger/icon/color/jaeger-icon-color.png` | `*.jaegertracing.io` |
| karmada.png | Karmada | `projects/karmada/icon/color/karmada-icon-color.png` | `*.karmada.io` |
| keda.png | KEDA | `projects/keda/icon/color/keda-icon-color.png` | `keda.sh`, `*.keda.sh` |
| knative.png | Knative | `projects/knative/icon/color/knative-icon-color.png` | `*.knative.dev` |
| kubeflow.png | Kubeflow | `projects/kubeflow/icon/color/kubeflow-icon.png` | `*.kubeflow.org` |
| kubernetes.png | Kubernetes | `projects/kubernetes/icon/color/kubernetes-icon-color.png` | `*.k8s.io`, `*.x-k8s.io` (Gateway API, snapshots, Cluster API, …) |
| kubevirt.png | KubeVirt | `projects/kubevirt/icon/color/kubevirt-icon-color.png` | `*.kubevirt.io` |
| kyverno.png | Kyverno | `projects/kyverno/icon/color/kyverno-icon-color.png` | `kyverno.io`, `*.kyverno.io` |
| linkerd.png | Linkerd | `projects/linkerd/icon/color/linkerd-icon-color.png` | `*.linkerd.io` |
| longhorn.png | Longhorn | `projects/longhorn/icon/color/longhorn-icon-color.png` | `longhorn.io` |
| metallb.png | MetalLB | `projects/metallb/icon/color/metallb-icon-color.png` | `metallb.io` |
| opa.png | Open Policy Agent (Gatekeeper) | `projects/open-policy-agent/icon/color/opa-icon-color.png` | `*.gatekeeper.sh`, `*.openpolicyagent.org` |
| openkruise.png | OpenKruise | `projects/openkruise/icon/color/openkruise-icon-color.png` | `*.kruise.io` |
| opentelemetry.png | OpenTelemetry | `projects/opentelemetry/icon/color/opentelemetry-icon-color.png` | `opentelemetry.io` |
| operatorframework.png | Operator Framework (OLM) | `projects/operatorframework/icon/color/operatorframework-icon-color.png` | `operators.coreos.com` |
| prometheus.png | Prometheus (Prometheus Operator) | `projects/prometheus/icon/color/prometheus-icon-color.png` | `monitoring.coreos.com` |
| rook.png | Rook | `projects/rook/icon/color/rook-icon-color.png` | `*.rook.io` |
| strimzi.png | Strimzi | `projects/strimzi/icon/color/strimzi-icon-color.png` | `*.strimzi.io` |
| tekton.png | Tekton | `projects/tekton/icon/color/tekton-icon-color.png` | `*.tekton.dev` |
| thanos.png | Thanos | `projects/thanos/icon/color/thanos-icon-color.png` | `*.thanos.io` |
| velero.png | Velero | `projects/velero/icon/color/velero-icon-color.png` | `velero.io` |
| volcano.png | Volcano | `projects/volcano/icon/color/volcano-icon-color.png` | `*.volcano.sh` |

## Other sources

| File | Project | Source | Licence | API groups |
|---|---|---|---|---|
| trivy.png | Trivy (Trivy Operator) | <https://github.com/aquasecurity/trivy/blob/main/docs/imgs/logo.png>, cropped to the cube mark | Repository licensed Apache-2.0; "Trivy" and "Aqua" are trademarks of Aqua Security | `aquasecurity.github.io` |

Not bundled: Calico (projectcalico.org) has no CNCF artwork entry and no clearly
licensed icon file, so it resolves at runtime through its Helm chart icon or
favicon, or falls back to a monogram.

## Operating systems

Small monochrome glyphs for a node's base OS or distribution, in
`assets/icons/os/`. They are used only to label nodes that run that OS
(nominative use); no endorsement is implied, and all marks belong to their
owners. Each was downloaded on 2026-11-09 as SVG, rasterised, reduced to a
single-colour alpha mask (dark ink opaque, white details cut out), cropped to
its visible content, padded square and downscaled to 64×64 PNG. The app tints
them with the theme's hint colour. The detection lives in
`lib/util/node_os.dart`, the widget in `lib/ui/widgets/node_os_icon.dart`.

[Simple Icons](https://simpleicons.org) SVGs (v16.37.0, `icons/<slug>.svg`)
are released under CC0-1.0; the marks themselves remain trademarks, and the
owners' terms are linked where Simple Icons records them.

| File | OS | Source | Licence / terms |
|---|---|---|---|
| talos.png | Talos Linux | Simple Icons `talos` (from the siderolabs/talos website logo) | CC0-1.0 SVG; "Talos" is a trademark of Sidero Labs |
| ubuntu.png | Ubuntu | Simple Icons `ubuntu` (from <https://design.ubuntu.com/resources>) | CC0-1.0 SVG; Canonical trademark, [brand guidelines](https://design.ubuntu.com/brand) |
| fedora.png | Fedora, Fedora CoreOS | Simple Icons `fedora` (from <https://docs.fedoraproject.org/en-US/project/brand/>) | CC0-1.0 SVG; Red Hat trademark, [Fedora trademark guidelines](https://fedoraproject.org/wiki/Legal:Trademark_guidelines) |
| debian.png | Debian | Simple Icons `debian` (from <https://www.debian.org/logos>) | Debian Open Use Logo, CC-BY-SA-3.0 (Software in the Public Interest) |
| rockylinux.png | Rocky Linux | Simple Icons `rockylinux` (from rocky-linux/branding `logo/src/icon-black.svg`) | CC-BY-SA-4.0 (Rocky Enterprise Software Foundation) |
| almalinux.png | AlmaLinux | Simple Icons `almalinux` (from <https://almalinux.org>) | CC0-1.0 SVG; [AlmaLinux trademark usage policy](https://almalinux.org/p/the-almalinux-os-trademark-usage-policy/) |
| opensuse.png | openSUSE | Simple Icons `opensuse` (from openSUSE/artwork) | CC0-1.0 SVG; SUSE trademark, [openSUSE artwork guidelines](https://en.opensuse.org/Portal:Artwork) |
| linux.png | Any other Linux (Tux) | Simple Icons `linux` | CC0-1.0 SVG; Tux by Larry Ewing (lewing@isc.tamu.edu), drawn with The GIMP |
| k3s.png | k3s, when the host OS is not recognised | CNCF artwork `projects/k3s/icon/black/k3s-icon-black.svg` | Linux Foundation trademark usage guidelines (see CNCF artwork above) |
| kubernetes.png | kind, minikube | CNCF artwork `projects/kubernetes/icon/black/kubernetes-icon-black.svg` | Linux Foundation trademark usage guidelines (see CNCF artwork above) |

Not bundled, drawn instead as a neutral letter badge in the same tint:
Amazon Linux and Azure Linux / CBL-Mariner ("A"), Bottlerocket ("B"),
Container-Optimized OS ("C"), Flatcar ("F": its CNCF icon is a wordmark,
unreadable at 14 px), RHEL and RHEL CoreOS ("R": Red Hat's guidelines ask
for permission to use its logo), SLES and SLE Micro ("S") and k0s ("k").
Amazon, Google and Microsoft marks are not in Simple Icons at their owners'
request. Windows nodes use the Material Icons `window` glyph (Apache-2.0),
not the Windows logo.
