/// Future-driven section widgets: loading spinner, error message, data.
/// Exported by `common.dart`.
library;

import 'package:flutter/material.dart';

import 'common.dart' show InlineMessage;

/// The small centred spinner a section shows while loading.
class SectionSpinner extends StatelessWidget {
  final double size;
  final double strokeWidth;
  const SectionSpinner({super.key, this.size = 16, this.strokeWidth = 2});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Center(
      child: SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(strokeWidth: strokeWidth),
      ),
    ),
  );
}

/// Runs [future] and renders loading / error / data states.
class AsyncSection<T> extends StatelessWidget {
  final Future<T> future;
  final Widget Function(BuildContext, T) builder;
  const AsyncSection({super.key, required this.future, required this.builder});

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
    future: future,
    builder: (context, snap) {
      if (snap.hasError) return InlineMessage('${snap.error}', isError: true);
      if (snap.connectionState != ConnectionState.done && !snap.hasData) return const SectionSpinner(size: 14, strokeWidth: 1.5);
      return builder(context, snap.data as T);
    },
  );
}

/// Like [AsyncSection], but keeps showing the previous data while a refetch
/// is in flight (no spinner flash on live refreshes).
class KeepingAsync<T> extends StatelessWidget {
  final Future<T> future;
  final Widget Function(BuildContext, T) builder;
  const KeepingAsync({super.key, required this.future, required this.builder});

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
    future: future,
    builder: (context, snap) {
      if (snap.hasError) return InlineMessage('${snap.error}', isError: true);
      if (!snap.hasData) return const SectionSpinner();
      return builder(context, snap.data as T);
    },
  );
}

/// Runs a fetch once per [deps] value (not on every live re-render).
class FetchOnce<T> extends StatefulWidget {
  final Object? deps;
  final Future<T> Function() fetch;
  final Widget Function(BuildContext context, T data) builder;
  final Widget Function(BuildContext context, Object error)? errorBuilder;
  final Widget? loading;
  const FetchOnce({super.key, required this.deps, required this.fetch, required this.builder, this.errorBuilder, this.loading});

  @override
  State<FetchOnce<T>> createState() => _FetchOnceState<T>();
}

class _FetchOnceState<T> extends State<FetchOnce<T>> {
  late Future<T> _future = widget.fetch();

  @override
  void didUpdateWidget(covariant FetchOnce<T> old) {
    super.didUpdateWidget(old);
    if (old.deps != widget.deps) _future = widget.fetch();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
    future: _future,
    builder: (context, snap) {
      if (snap.hasError) {
        return widget.errorBuilder?.call(context, snap.error!) ?? InlineMessage('${snap.error}', isError: true);
      }
      if (snap.connectionState != ConnectionState.done) return widget.loading ?? const SectionSpinner();
      return widget.builder(context, snap.data as T);
    },
  );
}
