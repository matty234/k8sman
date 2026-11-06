import 'dart:collection';

/// A bounded, append-only list: past [capacity] the oldest items are
/// overwritten in place (no shifting the whole list on every flush). Reads
/// as an ordinary read-only list, oldest first. Holds log lines
/// ([LogBuffer]) and streamed rows ([FrameStream], e.g. Hubble flows).
///
/// Also numbers items with a running sequence ([firstSeq] is the number of
/// `this[0]`), so per-item state such as search matches can be kept
/// incrementally across evictions.
class RingBuffer<T> extends ListBase<T> {
  final int capacity;
  RingBuffer(this.capacity) : assert(capacity > 0);

  // Grows to [capacity], then wraps; [_head] is the oldest line once full.
  final List<T> _buf = [];
  int _head = 0;
  int _firstSeq = 0;

  /// Sequence number of `this[0]` (lines evicted or cleared so far).
  int get firstSeq => _firstSeq;

  /// Sequence number the next appended line will get.
  int get nextSeq => _firstSeq + _buf.length;

  @override
  int get length => _buf.length;

  @override
  set length(int n) {
    if (n != 0) throw UnsupportedError('RingBuffer can only be cleared');
    clear();
  }

  @override
  T operator [](int i) {
    RangeError.checkValidIndex(i, this);
    final j = _head + i;
    return _buf[j < _buf.length ? j : j - _buf.length];
  }

  @override
  void operator []=(int i, T v) => throw UnsupportedError('RingBuffer is append-only');

  @override
  void add(T element) => append([element]);

  @override
  void addAll(Iterable<T> iterable) => append(iterable);

  /// Appends [lines], evicting the oldest past [capacity]. Returns how many
  /// items were evicted.
  int append(Iterable<T> lines) {
    var evicted = 0;
    for (final l in lines) {
      if (_buf.length < capacity) {
        _buf.add(l);
      } else {
        _buf[_head] = l;
        _head = _head + 1 == capacity ? 0 : _head + 1;
        evicted++;
      }
    }
    _firstSeq += evicted;
    return evicted;
  }

  @override
  void clear() {
    _firstSeq += _buf.length;
    _buf.clear();
    _head = 0;
  }
}
