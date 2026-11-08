import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/ui/kubectl_menu.dart';
import 'package:k8sman/util/kubectl.dart';

void main() {
  test('kubectl command builder', () {
    const pod = ResourceType(group: '', version: 'v1', resource: 'pods', kind: 'Pod');
    const node = ResourceType(group: '', version: 'v1', resource: 'nodes', kind: 'Node', namespaced: false);
    const app = ResourceType(group: 'argoproj.io', version: 'v1alpha1', resource: 'applications', kind: 'Application');
    const plain = KubectlEnv(context: 'kind-dev');
    const odd = KubectlEnv(context: 'admin@prod cluster', kubeconfig: "/Users/o'neil/kube config");

    expect(plain.get(pod, [(namespace: 'ns', name: 'a')]), 'kubectl get pod a -o yaml -n ns --context kind-dev');
    expect(plain.describe(node, [(namespace: null, name: 'n1')]), 'kubectl describe node n1 --context kind-dev');
    expect(plain.get(app, [(namespace: 'argocd', name: 'x')]), 'kubectl get applications.argoproj.io x -o yaml -n argocd --context kind-dev');
    expect(odd.describe(node, [(namespace: null, name: 'n1')]), "kubectl describe node n1 --context 'admin@prod cluster' --kubeconfig '/Users/o'\\''neil/kube config'");
    expect(plain.describe(pod, [(namespace: 'a', name: 'p1'), (namespace: 'b', name: 'p2'), (namespace: 'a', name: 'p3')]),
        'kubectl describe pod p1 p3 -n a --context kind-dev\nkubectl describe pod p2 -n b --context kind-dev');
    expect(plain.exec((namespace: 'ns', name: 'p'), container: 'main'), 'kubectl exec -it p -c main -n ns --context kind-dev -- sh');
    expect(plain.logs((namespace: 'ns', name: 'p')), 'kubectl logs p -f -n ns --context kind-dev');

    Map<String, dynamic> podWith(List<String> cs, [String? annotated]) => {
          'metadata': {if (annotated != null) 'annotations': {'kubectl.kubernetes.io/default-container': annotated}},
          'spec': {'containers': [for (final c in cs) {'name': c}]},
        };
    expect(kubectlPodContainer(podWith(['app', 'proxy'], 'proxy')), 'proxy');
    expect(kubectlPodContainer(podWith(['app', 'proxy'])), 'app');
    expect(kubectlPodContainer(podWith(['app'])), isNull);
  });
}
