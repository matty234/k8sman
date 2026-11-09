import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/nodes/nodes_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/util/node_os.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';
import '../support/screenshot.dart';

Json _node(String image, {String name = 'n', String os = 'linux', String kubelet = 'v1.31.0', String runtime = 'containerd://1.7.2', String? provider, Map<String, String> labels = const {}, String ip = '10.0.0.1'}) => {
      'metadata': {'name': name, 'labels': labels, 'creationTimestamp': '2026-11-01T00:00:00Z'},
      'spec': {'providerID': ?provider},
      'status': {
        'nodeInfo': {'osImage': image, 'operatingSystem': os, 'kubeletVersion': kubelet, 'containerRuntimeVersion': runtime},
        'addresses': [
          {'type': 'InternalIP', 'address': ip},
        ],
        'allocatable': {'cpu': '4', 'memory': '16Gi', 'pods': '110'},
        'conditions': [
          {'type': 'Ready', 'status': 'True'},
        ],
      },
    };

void main() {
  test('nodeOsOf recognises distributions and platforms', () {
    String? os(Json n) => nodeOsOf(n)?.label;
    expect(os(_node('Talos (v1.8.0)')), 'Talos');
    expect(os(_node('Amazon Linux 2023.5.20240624', kubelet: 'v1.30.0-eks-036c24b', provider: 'aws:///us-east-1a/i-0abc')), 'Amazon Linux · EKS');
    expect(os(_node('Bottlerocket OS 1.20.0 (aws-k8s-1.29)', labels: {'eks.amazonaws.com/nodegroup': 'ng'})), 'Bottlerocket · EKS');
    expect(os(_node('Container-Optimized OS from Google', kubelet: 'v1.30.5-gke.1014001', provider: 'gce://p/z/n')), 'Container-Optimized OS · GKE');
    expect(os(_node('Ubuntu 22.04.4 LTS', labels: {'kubernetes.azure.com/agentpool': 'np'}, provider: 'azure:///subscriptions/x')), 'Ubuntu · AKS');
    expect(os(_node('CBL-Mariner/Linux', labels: {'kubernetes.azure.com/os-sku': 'CBLMariner'})), 'Azure Linux · AKS');
    expect(os(_node('Azure Linux 3.0')), 'Azure Linux');
    expect(os(_node('Fedora CoreOS 40.20240616.3.0')), 'Fedora CoreOS');
    expect(os(_node('Flatcar Container Linux by Kinvolk 3815.2.5 (Oklo)')), 'Flatcar');
    expect(os(_node('Debian GNU/Linux 12 (bookworm)')), 'Debian');
    expect(os(_node('Red Hat Enterprise Linux CoreOS 416.94', labels: {'node.openshift.io/os_id': 'rhcos'})), 'RHEL CoreOS · OpenShift');
    expect(os(_node('Rocky Linux 9.4 (Blue Onyx)')), 'Rocky Linux');
    expect(os(_node('AlmaLinux 9.4 (Seafoam Ocelot)')), 'AlmaLinux');
    expect(os(_node('openSUSE Leap Micro 5.5')), 'openSUSE');
    expect(os(_node('SUSE Linux Enterprise Micro 5.5')), 'SLE Micro');
    expect(os(_node('SUSE Linux Enterprise Server 15 SP6')), 'SLES');
    expect(os(_node('SLE Micro 6.0')), 'SLE Micro');
    expect(os(_node('Windows Server 2022 Datacenter', os: 'windows')), 'Windows');
    expect(os(_node('Ubuntu 24.04.1 LTS', kubelet: 'v1.31.1+k3s1')), 'Ubuntu · k3s');
    expect(os(_node('K3s v1.30.4+k3s1', kubelet: 'v1.30.4+k3s1')), 'k3s');
    expect(os(_node('Gentoo Linux 2.15', kubelet: 'v1.31.0+k0s')), 'k0s');
    expect(os(_node('Debian GNU/Linux 12 (bookworm)', provider: 'kind://docker/dev/dev-control-plane')), 'kind');
    expect(os(_node('Buildroot 2023.02.9', labels: {'minikube.k8s.io/name': 'minikube'})), 'minikube');
    expect(nodeOsOf(_node('Bottlerocket OS 1.20.0', kubelet: 'v1.29.0-eks-a1'))?.tooltip, 'Bottlerocket OS 1.20.0 · EKS · containerd 1.7.2');
    expect(nodeOsOf({'metadata': {'name': 'bare'}}), isNull);
  });

  testWidgets('node rows show the OS icon with its tooltip', (tester) async {
    await loadRealFonts();
    final nodes = [
      _node('Talos (v1.8.0)', name: 'talos-cp-1', ip: '10.5.0.2', labels: {'node-role.kubernetes.io/control-plane': ''}),
      _node('Bottlerocket OS 1.20.0 (aws-k8s-1.29)', name: 'ip-10-0-3-17.ec2.internal', kubelet: 'v1.29.3-eks-ae9a62a', ip: '10.0.3.17', labels: {'node.kubernetes.io/instance-type': 'm7g.large'}),
      _node('Amazon Linux 2023.5.20240624', name: 'ip-10-0-4-22.ec2.internal', kubelet: 'v1.30.0-eks-036c24b', ip: '10.0.4.22', labels: {'node.kubernetes.io/instance-type': 'm6i.xlarge'}),
      _node('Container-Optimized OS from Google', name: 'gke-prod-default-pool-1a2b', kubelet: 'v1.30.5-gke.1014001', ip: '10.128.0.9'),
      _node('Ubuntu 22.04.4 LTS', name: 'aks-nodepool1-0', ip: '10.224.0.4', labels: {'kubernetes.azure.com/role': 'agent'}),
      _node('CBL-Mariner/Linux', name: 'aks-nodepool2-0', ip: '10.224.0.5', labels: {'kubernetes.azure.com/role': 'agent'}),
      _node('Fedora CoreOS 40.20240616.3.0', name: 'fcos-worker', ip: '192.168.1.20'),
      _node('Flatcar Container Linux by Kinvolk 3815.2.5', name: 'flatcar-worker', ip: '192.168.1.21'),
      _node('Debian GNU/Linux 12 (bookworm)', name: 'debian-worker', ip: '192.168.1.22'),
      _node('Rocky Linux 9.4 (Blue Onyx)', name: 'rocky-worker', ip: '192.168.1.23'),
      _node('Ubuntu 24.04.1 LTS', name: 'k3s-agent', kubelet: 'v1.31.1+k3s1', ip: '192.168.1.24'),
      _node('Windows Server 2022 Datacenter', name: 'akswin000000', os: 'windows', runtime: 'containerd://1.7.20+azure', ip: '10.224.0.9'),
      _node('Debian GNU/Linux 12 (bookworm)', name: 'kind-control-plane', provider: 'kind://docker/kind/kind-control-plane', ip: '172.18.0.2'),
    ];
    final api = FakeApiClient(itemsByResource: {'nodes': nodes, 'pods': const <Json>[]});
    final app = AppState(api)
      ..types = testTypes
      ..currentContext = 'kind-k8sman-dev';
    tester.view.physicalSize = const Size(1100, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.dark), home: const Scaffold(body: NodesView())),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200))); // decode the PNGs
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('node-os/talos')), findsOneWidget);
    expect(find.byTooltip('Bottlerocket OS 1.20.0 (aws-k8s-1.29) · EKS · containerd 1.7.2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // dispose the poll timer
  });
}
