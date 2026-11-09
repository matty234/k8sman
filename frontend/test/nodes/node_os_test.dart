import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/util/node_os.dart';


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

}
