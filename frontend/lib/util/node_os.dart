/// Which base OS or distribution a node runs, from its `status.nodeInfo`,
/// labels and provider ID (pure, for tests). The icon lives in
/// lib/ui/widgets/node_os_icon.dart.
library;

import '../api/models.dart';
import 'k8s.dart';

/// How an OS is drawn: a bundled glyph (`assets/icons/os/<asset>.png`), a
/// neutral letter badge where no logo is usable, or a generic glyph.
enum NodeOsMark {
  talos(asset: 'talos'),
  amazonLinux(letter: 'A'),
  bottlerocket(letter: 'B'),
  cos(letter: 'C'),
  azureLinux(letter: 'A'),
  ubuntu(asset: 'ubuntu'),
  fedora(asset: 'fedora'),
  flatcar(letter: 'F'),
  debian(asset: 'debian'),
  redHat(letter: 'R'),
  rocky(asset: 'rockylinux'),
  alma(asset: 'almalinux'),
  opensuse(asset: 'opensuse'),
  suse(letter: 'S'),
  k3s(asset: 'k3s'),
  k0s(letter: 'k'),
  kubernetes(asset: 'kubernetes'),
  windows(),
  linux(asset: 'linux');

  final String? asset;
  final String? letter;
  const NodeOsMark({this.asset, this.letter});
}

class NodeOs {
  /// Short name: "Bottlerocket", "Ubuntu", "Talos".
  final String name;

  /// Managed service or Kubernetes distribution: "EKS", "AKS", "k3s".
  final String? platform;

  /// The raw `osImage`.
  final String? image;

  /// "containerd 1.7.2".
  final String? runtime;
  final NodeOsMark mark;
  const NodeOs(this.name, this.mark, {this.platform, this.image, this.runtime});

  /// "Bottlerocket · EKS".
  String get label => platform == null ? name : '$name · $platform';

  /// "Bottlerocket OS 1.20.0 (aws-k8s-1.29) · EKS · containerd 1.6.28".
  String get tooltip => [image ?? name, ?platform, ?runtime].join(' · ');

  @override
  String toString() => label;
}

/// The node's OS and platform; null when the node reports neither an OS
/// image nor an operating system.
NodeOs? nodeOsOf(Json node) {
  final info = asMap(dig(node, ['status', 'nodeInfo']));
  final labels = asMap(dig(node, ['metadata', 'labels']));
  final image = _str(info['osImage']);
  final os = (_str(info['operatingSystem']) ?? _str(labels['kubernetes.io/os']))?.toLowerCase();
  if (image == null && os == null) return null;
  final kubelet = (_str(info['kubeletVersion']) ?? '').toLowerCase();
  final provider = (_str(dig(node, ['spec', 'providerID'])) ?? '').toLowerCase();
  final img = (image ?? '').toLowerCase();
  bool label(String prefix) => labels.keys.any((k) => k.startsWith(prefix));

  final platform = switch (true) {
    _ when kubelet.contains('-eks-') || label('eks.amazonaws.com/') => 'EKS',
    _ when kubelet.contains('-gke.') || label('cloud.google.com/gke-') => 'GKE',
    _ when label('kubernetes.azure.com/') => 'AKS',
    _ when kubelet.contains('+k3s') || img.startsWith('k3s') => 'k3s',
    _ when kubelet.contains('+rke2') => 'RKE2',
    _ when kubelet.contains('+k0s') => 'k0s',
    _ when provider.startsWith('kind://') => 'kind',
    _ when label('minikube.k8s.io/') => 'minikube',
    _ when label('node.openshift.io/') => 'OpenShift',
    _ when provider.startsWith('aws://') => 'AWS',
    _ when provider.startsWith('gce://') => 'GCE',
    _ when provider.startsWith('azure://') => 'Azure',
    _ => null,
  };
  final runtime = _runtime(_str(info['containerRuntimeVersion']));
  NodeOs of(String name, NodeOsMark mark, {String? platform}) => NodeOs(name, mark, platform: platform, image: image, runtime: runtime);

  // kind and minikube nodes run the tool's own image (Debian-based for
  // kind, Buildroot for minikube): the tool is the more useful answer.
  if (platform == 'kind' || platform == 'minikube') return of(platform!, NodeOsMark.kubernetes);
  if (os == 'windows' || img.contains('windows')) return of('Windows', NodeOsMark.windows, platform: platform);

  final distro = switch (img) {
    _ when img.startsWith('talos') => ('Talos', NodeOsMark.talos),
    _ when img.contains('bottlerocket') => ('Bottlerocket', NodeOsMark.bottlerocket),
    _ when img.contains('amazon linux') => ('Amazon Linux', NodeOsMark.amazonLinux),
    _ when img.contains('container-optimized os') => ('Container-Optimized OS', NodeOsMark.cos),
    _ when img.contains('mariner') || img.contains('azure linux') => ('Azure Linux', NodeOsMark.azureLinux),
    _ when img.contains('fedora coreos') => ('Fedora CoreOS', NodeOsMark.fedora),
    _ when img.contains('fedora') => ('Fedora', NodeOsMark.fedora),
    _ when img.contains('flatcar') => ('Flatcar', NodeOsMark.flatcar),
    _ when img.contains('red hat enterprise linux coreos') || img.startsWith('rhcos') => ('RHEL CoreOS', NodeOsMark.redHat),
    _ when img.contains('red hat') => ('RHEL', NodeOsMark.redHat),
    _ when img.contains('rocky') => ('Rocky Linux', NodeOsMark.rocky),
    _ when img.contains('almalinux') => ('AlmaLinux', NodeOsMark.alma),
    _ when img.contains('ubuntu') => ('Ubuntu', NodeOsMark.ubuntu),
    _ when img.contains('debian') => ('Debian', NodeOsMark.debian),
    _ when img.contains('opensuse') => ('openSUSE', NodeOsMark.opensuse),
    _ when img.contains('sle micro') || img.contains('enterprise micro') || img.contains('sl-micro') => ('SLE Micro', NodeOsMark.suse),
    _ when img.contains('suse') || img.startsWith('sles') => ('SLES', NodeOsMark.suse),
    _ => null,
  };
  if (distro != null) return of(distro.$1, distro.$2, platform: platform);
  // An unrecognised Linux: the distribution's own mark if it has one.
  if (platform == 'k3s') return of('k3s', NodeOsMark.k3s);
  if (platform == 'k0s') return of('k0s', NodeOsMark.k0s);
  return of(_firstWords(image) ?? 'Linux', NodeOsMark.linux, platform: platform);
}

String? _str(dynamic v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

/// "containerd://1.7.2" → "containerd 1.7.2".
String? _runtime(String? v) => v?.replaceFirst('://', ' ');

/// "Gentoo Linux 2.15" → "Gentoo Linux": the name without its version.
String? _firstWords(String? image) {
  if (image == null) return null;
  final m = RegExp(r'^[^\d(]+').firstMatch(image);
  final s = m?.group(0)?.trim();
  return s == null || s.isEmpty ? image : s;
}

/// The node-shaped JSON behind a Nodes table "nodeos" cell: the backend
/// column (backend/internal/columns/builtin.go) emits osImage,
/// operatingSystem, kubeletVersion, containerRuntimeVersion, providerID and
/// the first platform label, tab-separated.
Json nodeFromOsCell(String cell) {
  final f = cell.split('\t');
  String at(int i) => i < f.length ? f[i] : '';
  return {
    'metadata': {
      'labels': {if (at(5).isNotEmpty) at(5): ''},
    },
    'spec': {'providerID': at(4)},
    'status': {
      'nodeInfo': {'osImage': at(0), 'operatingSystem': at(1), 'kubeletVersion': at(2), 'containerRuntimeVersion': at(3)},
    },
  };
}
