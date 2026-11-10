import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../util/k8s.dart';
import 'cache.dart';
import 'metrics_api.dart';
import '../state/poller.dart';

/// Loads one pod's usage (shared per namespace, refreshed every 15s).
class PodUsageLoader extends StatefulWidget {
  final String namespace;
  final String name;
  final Widget Function(BuildContext context, PodUsage? usage, Object? error, bool loading) builder;
  const PodUsageLoader({super.key, required this.namespace, required this.name, required this.builder});

  @override
  State<PodUsageLoader> createState() => _PodUsageLoaderState();
}

class _PodUsageLoaderState extends State<PodUsageLoader> with PollingState {
  PodUsage? _usage;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    poll(const Duration(seconds: 15), () async {
      await _load();
      return _error == null;
    });
  }

  @override
  void didUpdateWidget(PodUsageLoader old) {
    super.didUpdateWidget(old);
    if (old.name != widget.name || old.namespace != widget.namespace) _load();
  }

  Future<void> _load() async {
    try {
      final u = await MetricsCache.of(context.read<ApiClient>()).pod(widget.namespace, widget.name);
      if (!mounted) return;
      setState(() {
        _usage = u;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _usage = null;
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _usage, _error, _loading);
}

/// Requests/limits of one container spec, in millicores and bytes.
({double? cpuReq, double? cpuLim, double? memReq, double? memLim}) containerResources(Json spec) {
  final r = asMap(spec['resources']);
  final req = asMap(r['requests']), lim = asMap(r['limits']);
  return (cpuReq: parseCpuMillis(req['cpu']), cpuLim: parseCpuMillis(lim['cpu']), memReq: parseBytes(req['memory']), memLim: parseBytes(lim['memory']));
}

/// The value text for usage against a request/limit: "8m / 200m lim".
String usageAgainst(String used, {String? limit, String? request}) {
  if (limit != null) return '$used / $limit lim';
  if (request != null) return '$used / $request req';
  return used;
}
