import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/panels/argocd/argo_managed.dart';

void main() {
  test('argoTrackingApp reads the managing app from the tracking annotation', () {
    Map<String, dynamic> obj(String id) => {
          'metadata': {
            'annotations': {'argocd.argoproj.io/tracking-id': id},
          },
        };
    expect(argoTrackingApp(obj('lda:dragonflydb.io/Dragonfly:lda/lda-dragonfly'), name: 'lda-dragonfly'), (namespace: null, name: 'lda'));
    expect(argoTrackingApp(obj('team_web:apps/Deployment:web/api'), name: 'api'), (namespace: 'team', name: 'web'));
    // Copied from another object (e.g. a template): not ours.
    expect(argoTrackingApp(obj('lda:apps/Deployment:lda/other'), name: 'lda-dragonfly'), isNull);
    expect(argoTrackingApp(const {'metadata': {}}, name: 'x'), isNull);
  });
}
