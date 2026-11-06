import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/state/namespace_scope.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/table_controller.dart';

const pvcs = ResourceType(group: '', version: 'v1', resource: 'persistentvolumeclaims', kind: 'PersistentVolumeClaim');

class _Api extends ApiClient {
  final List<dynamic> capacities;
  _Api(this.capacities) : super(base: Uri.parse('http://fake'));
  @override
  Stream<WatchMessage> watch(ResourceRef r, {String? namespace, NamespaceScope? scope, String? labelSelector, String? fieldSelector, bool includeObject = false}) =>
      Stream.value(WatchMessage(
        type: 'SNAPSHOT',
        table: TableData(
          resource: pvcs,
          // A plain string column, like the PVC "Capacity" default column.
          columns: const [ColumnDef(name: 'Capacity', query: '.status.capacity.storage')],
          isDefaultColumns: true,
          resourceVersion: '1',
          rows: [
            for (final (i, c) in capacities.indexed)
              TableRowData(uid: 'u$i', name: 'pvc-$i', namespace: 'demo', resourceVersion: '1', cells: [c]),
          ],
        ),
      ));
}

void main() {
  test('size columns sort by value with units, not as text', () async {
    final tc = TableController(api: _Api(['10Gi', '2Gi', '500Mi', '1Ti', null, '1.5Gi', '100M']), type: pvcs);
    await pumpEventQueue();
    tc.sortBy(0);
    expect(tc.rows.map((r) => r.cells.first).toList(), ['100M', '500Mi', '1.5Gi', '2Gi', '10Gi', '1Ti', null]);
    tc.sortBy(0); // descending: largest first, empty still last
    expect(tc.rows.map((r) => r.cells.first).toList(), ['1Ti', '10Gi', '2Gi', '1.5Gi', '500Mi', '100M', null]);
    tc.dispose();
  });

  test('CPU-style quantities and plain numbers sort by value', () async {
    final tc = TableController(api: _Api(['250m', '2', '1500m', '1', '50m']), type: pvcs);
    await pumpEventQueue();
    tc.sortBy(0);
    expect(tc.rows.map((r) => r.cells.first).toList(), ['50m', '250m', '1', '1500m', '2']);
    tc.dispose();
  });

  test('non-quantity text still sorts as text', () async {
    final tc = TableController(api: _Api(['Bound', 'Pending', 'Lost']), type: pvcs);
    await pumpEventQueue();
    tc.sortBy(0);
    expect(tc.rows.map((r) => r.cells.first).toList(), ['Bound', 'Lost', 'Pending']);
    tc.dispose();
  });
}
