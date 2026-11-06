import 'ring_buffer.dart';

export 'ring_buffer.dart';

/// The log viewer's line buffer: a [RingBuffer] of lines, or of per-line
/// metadata (aggregated logs keep source and timestamp alongside).
class LogBuffer<T> extends RingBuffer<T> {
  LogBuffer(super.capacity);
}
