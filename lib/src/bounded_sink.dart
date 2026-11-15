/// A [StringSink] that keeps only the last [limit] characters.
///
/// It is the default `out` of `Scheduler`. A long run writes many log
/// lines, and a plain `StringBuffer` would keep all of them.
/// `toString()` gives the kept text.
class BoundedSink implements StringSink {
  BoundedSink({this.limit = 65536});

  /// Max characters kept. When the text is longer, the oldest part goes.
  final int limit;

  final StringBuffer _buffer = StringBuffer();

  @override
  void write(Object? object) {
    _buffer.write(object);
    _trim();
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    _buffer.writeAll(objects, separator);
    _trim();
  }

  @override
  void writeCharCode(int charCode) {
    write(String.fromCharCode(charCode));
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
    write('\n');
  }

  /// Trim at 2 x limit only, so most writes cost nothing.
  void _trim() {
    if (_buffer.length <= limit * 2) return;
    String text = _buffer.toString();
    _buffer.clear();
    _buffer.write(_tail(text));
  }

  /// The last [limit] code units of [text]. If the cut leaves a low
  /// surrogate first, drop it too, so no broken pair stays.
  String _tail(String text) {
    if (text.length <= limit) return text;
    int start = text.length - limit;
    int unit = text.codeUnitAt(start);
    if (unit >= 0xDC00 && unit <= 0xDFFF) start++;
    return text.substring(start);
  }

  /// The kept text. At most 2 x [limit] characters between trims, so cut
  /// to [limit] here.
  @override
  String toString() {
    return _tail(_buffer.toString());
  }
}
