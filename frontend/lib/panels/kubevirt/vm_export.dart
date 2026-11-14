import 'dart:async';

import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../api/backend_http.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../app/kubeconfig_picker.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';

/// KubeVirt disk export, natively (no virtctl): the backend creates a
/// VirtualMachineExport (or adopts an existing one), waits for it, and
/// downloads a volume through a port-forward straight into the file chosen
/// here (it runs on this machine); see backend/internal/server/vmexport.go.

/// Action ids.
const String kVmExportActionId = 'vm-export';
const String kVmExportDownloadActionId = 'vm-export-download';

/// "Export disk…" on a VirtualMachine (and on a PersistentVolumeClaim when
/// the cluster serves VirtualMachineExports); "Download…" on a
/// VirtualMachineExport. Creating an export is hidden on read-only
/// contexts; downloading an existing one only reads.
List<ResourceAction> vmExportActions(PanelContext ctx) {
  final ns = ctx.namespace;
  if (ns == null) return const [];
  switch (ctx.type.gk) {
    case 'kubevirt.io/VirtualMachine':
      if (ctx.app.readOnly) return const [];
      final running = ctx.status['printableStatus'] == 'Running' || ctx.status['ready'] == true;
      return [
        ResourceAction(
          id: kVmExportActionId,
          label: 'Export disk…',
          icon: Icons.download_outlined,
          tooltip: 'Download a disk of this VM (KubeVirt VirtualMachineExport)',
          run: (context) => showVmExportDialog(context, ctx.api, namespace: ns, kind: 'VirtualMachine', name: ctx.name, vmRunning: running),
        ),
      ];
    case '/PersistentVolumeClaim':
      if (ctx.app.readOnly || ctx.app.typeFor('export.kubevirt.io', 'VirtualMachineExport') == null) return const [];
      return [
        ResourceAction(
          id: kVmExportActionId,
          label: 'Export disk…',
          icon: Icons.download_outlined,
          advanced: true,
          tooltip: 'Download this volume (KubeVirt VirtualMachineExport)',
          run: (context) => showVmExportDialog(context, ctx.api, namespace: ns, kind: 'PersistentVolumeClaim', name: ctx.name),
        ),
      ];
    case 'export.kubevirt.io/VirtualMachineExport':
      return [
        ResourceAction(
          id: kVmExportDownloadActionId,
          label: 'Download…',
          icon: Icons.download_outlined,
          tooltip: 'Download a volume of this export',
          run: (context) => showVmExportDialog(context, ctx.api, namespace: ns, kind: 'VirtualMachineExport', name: ctx.name),
        ),
      ];
  }
  return const [];
}

Future<void> showVmExportDialog(BuildContext context, ApiClient api,
    {required String namespace, required String kind, required String name, bool vmRunning = false}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => VmExportDialog(api: api, namespace: namespace, kind: kind, name: name, vmRunning: vmRunning),
  );
}

/// The backend's export job (GET /api/vm-exports/{id}).
class VmExportJob {
  final String id;
  final String export;
  final bool created;

  /// waiting, ready, downloading, done, failed or cancelled.
  final String state;
  final String phase;
  final List<Json> conditions;
  final List<({String name, List<String> formats})> volumes;
  final String? error;
  final String? path;
  final int bytes;

  /// -1 when unknown (a compressed stream).
  final int total;

  const VmExportJob({
    required this.id,
    required this.export,
    required this.created,
    required this.state,
    this.phase = '',
    this.conditions = const [],
    this.volumes = const [],
    this.error,
    this.path,
    this.bytes = 0,
    this.total = -1,
  });

  bool get finished => state == 'done' || state == 'failed' || state == 'cancelled';

  factory VmExportJob.fromJson(Json j) => VmExportJob(
        id: '${j['id']}',
        export: '${j['export'] ?? ''}',
        created: j['created'] == true,
        state: '${j['state'] ?? ''}',
        phase: '${j['phase'] ?? ''}',
        conditions: [for (final c in (j['conditions'] as List? ?? const [])) Map<String, dynamic>.from(c as Map)],
        volumes: [
          for (final v in (j['volumes'] as List? ?? const []))
            (name: '${(v as Map)['name']}', formats: [for (final f in (v['formats'] as List? ?? const [])) '$f']),
        ],
        error: j['error'] as String?,
        path: j['path'] as String?,
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? -1,
      );
}

class _VmExportApi {
  final BackendHttp _http;
  _VmExportApi(ApiClient api) : _http = BackendHttp(api, '/api/vm-exports');

  Future<VmExportJob> start(String namespace, String kind, String name) async =>
      VmExportJob.fromJson(jsonObjectBody(await _http.send('POST', '', body: {'namespace': namespace, 'kind': kind, 'name': name})));
  Future<VmExportJob> get(String id) async => VmExportJob.fromJson(jsonObjectBody(await _http.get('/${Uri.encodeComponent(id)}')));
  Future<VmExportJob> download(String id, String volume, String format, String path) async => VmExportJob.fromJson(
      jsonObjectBody(await _http.send('POST', '/${Uri.encodeComponent(id)}/download', body: {'volume': volume, 'format': format, 'path': path})));
  Future<void> cancel(String id) => _http.send('DELETE', '/${Uri.encodeComponent(id)}');
}

/// File name and save-panel extensions for a format.
({String suffix, List<String> extensions, String label}) _formatFile(String format) => switch (format) {
      'gzip' => (suffix: '.img.gz', extensions: const ['gz'], label: 'Compressed disk image'),
      'tar.gz' => (suffix: '.tar.gz', extensions: const ['gz'], label: 'Archive'),
      _ => (suffix: '.img', extensions: const ['img', 'raw'], label: 'Disk image'),
    };

String _formatLabel(String format) => switch (format) {
      'gzip' => 'Raw, gzip-compressed (.img.gz)',
      'raw' => 'Raw (.img)',
      'tar.gz' => 'Archive (.tar.gz)',
      _ => format,
    };

class VmExportDialog extends StatefulWidget {
  final ApiClient api;
  final String namespace;
  final String kind;
  final String name;
  final bool vmRunning;
  const VmExportDialog({super.key, required this.api, required this.namespace, required this.kind, required this.name, this.vmRunning = false});

  @override
  State<VmExportDialog> createState() => _VmExportDialogState();
}

class _VmExportDialogState extends State<VmExportDialog> {
  late final _VmExportApi _api = _VmExportApi(widget.api);
  VmExportJob? _job;
  String? _error;
  String? _volume;
  String? _format;
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    final job = _job;
    // Closing the dialog ends the job: the backend deletes the export it
    // created (also if the app stops asking, after a minute).
    if (job != null && !job.finished) unawaited(_api.cancel(job.id).catchError((Object _) {}));
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final job = await _api.start(widget.namespace, widget.kind, widget.name);
      if (!mounted) {
        unawaited(_api.cancel(job.id).catchError((Object _) {}));
        return;
      }
      setState(() => _job = job);
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '$e');
    }
  }

  Future<void> _poll() async {
    final job = _job;
    if (job == null || job.finished) return;
    try {
      final next = await _api.get(job.id);
      if (!mounted) return;
      setState(() {
        _job = next;
        if (next.volumes.isNotEmpty && !next.volumes.any((v) => v.name == _volume)) _volume = next.volumes.first.name;
        final formats = _formats(next);
        if (formats.isNotEmpty && !formats.contains(_format)) _format = formats.first;
      });
      if (next.finished) _timer?.cancel();
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '$e');
      _timer?.cancel();
    }
  }

  List<String> _formats(VmExportJob job) => [
        for (final v in job.volumes)
          if (v.name == _volume) ...v.formats,
      ];

  Future<void> _download() async {
    final job = _job, volume = _volume, format = _format;
    if (job == null || volume == null || format == null) return;
    final f = _formatFile(format);
    final base = widget.kind == 'VirtualMachineExport' ? volume : '${widget.name}-$volume';
    String? path;
    try {
      path = await NativeFiles.chooseSavePath('$base${f.suffix}', extensions: f.extensions, label: f.label, confirm: 'Download');
    } on UnsupportedError {
      if (mounted) setState(() => _error = 'This platform has no save panel');
      return;
    }
    if (path == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final next = await _api.download(job.id, volume, format, path);
      if (mounted) setState(() => _job = next);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final job = _job;
    _timer?.cancel();
    if (job != null && !job.finished) {
      setState(() => _busy = true);
      // Waits for the backend's clean-up (the export deleted).
      await _api.cancel(job.id).catchError((Object _) {});
      _job = null; // nothing left for dispose to cancel
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final job = _job;
    final what = widget.kind == 'VirtualMachineExport' ? 'export ${widget.name}' : '${widget.kind == 'VirtualMachine' ? 'VM' : 'volume'} ${widget.name}';
    final children = <Widget>[];
    if (_error != null) {
      children.add(Text(_error!, style: TextStyle(color: theme.colorScheme.error)));
    } else if (job == null) {
      children.add(Row(children: [
        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Text(widget.kind == 'VirtualMachineExport' ? 'Reading the export…' : 'Creating the export…'),
      ]));
    } else {
      switch (job.state) {
        case 'waiting':
          children.add(Row(children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Expanded(child: Text('Waiting for ${job.export} to be ready${job.phase.isEmpty ? '' : ' (${job.phase})'}…')),
          ]));
          if (widget.vmRunning) {
            children.add(Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('The VM is running: KubeVirt exports its disks once it is stopped.', style: hint?.copyWith(color: theme.colorScheme.tertiary)),
            ));
          }
        case 'ready':
          final formats = _formats(job);
          if (job.volumes.length > 1) {
            children.add(InputDecorator(
              decoration: const InputDecoration(labelText: 'Volume', isDense: true),
              child: MenuSelect<String>(
                expand: true,
                value: _volume,
                options: [for (final v in job.volumes) (v.name, Text(v.name))],
                onChanged: (v) => setState(() {
                  _volume = v;
                  final fs = _formats(job);
                  if (!fs.contains(_format)) _format = fs.isEmpty ? null : fs.first;
                }),
              ),
            ));
          } else {
            children.add(Text('Volume: ${_volume ?? ''}'));
          }
          children.add(const SizedBox(height: 8));
          children.add(InputDecorator(
            decoration: const InputDecoration(labelText: 'Format', isDense: true),
            child: MenuSelect<String>(
              expand: true,
              value: _format,
              options: [for (final f in formats) (f, Text(_formatLabel(f)))],
              onChanged: (v) => setState(() => _format = v),
            ),
          ));
        case 'downloading':
          final known = job.total > 0;
          children.add(Text('Downloading to ${job.path ?? ''}', style: hint));
          children.add(const SizedBox(height: 8));
          children.add(LinearProgressIndicator(value: known ? (job.bytes / job.total).clamp(0, 1).toDouble() : null));
          children.add(const SizedBox(height: 6));
          children.add(Text(known ? '${formatBytes(job.bytes)} of ${formatBytes(job.total)}' : formatBytes(job.bytes)));
        case 'done':
          children.add(Text('Saved ${formatBytes(job.bytes)} to ${job.path ?? ''}'));
        case 'cancelled':
          children.add(const Text('Cancelled.'));
        default:
          children.add(Text(job.error ?? 'The export failed', style: TextStyle(color: theme.colorScheme.error)));
      }
      if (!job.finished && job.state != 'downloading' && job.conditions.isNotEmpty) {
        children.add(const SizedBox(height: 10));
        for (final c in job.conditions) {
          children.add(Text(
            '${c['type']}: ${c['status']}${(c['reason'] ?? '') == '' ? '' : ' (${c['reason']})'}${(c['message'] ?? '') == '' ? '' : ' — ${c['message']}'}',
            style: hint,
          ));
        }
      }
      if (job.created && !job.finished) {
        children.add(const SizedBox(height: 10));
        children.add(Text('k8sman deletes ${job.export} when the download ends or is cancelled.', style: hint));
      }
    }
    final finished = _error != null || (job?.finished ?? false);
    return AlertDialog(
      title: Text('Export disk of $what'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
      actions: [
        if (finished) ...[
          if (job?.state == 'done' && job?.path != null) TextButton(onPressed: () => NativeFiles.reveal(job!.path!), child: Text(revealLabel)),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ] else ...[
          TextButton(onPressed: _busy ? null : _cancel, child: const Text('Cancel')),
          if (job?.state == 'ready')
            FilledButton(onPressed: _busy || _volume == null || _format == null ? null : _download, child: const Text('Download…')),
        ],
      ],
    );
  }
}
