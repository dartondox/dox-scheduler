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
    // Trim at 2 x limit only, so most writes cost nothing.
    if (_buffer.length > limit * 2) {
      String text = _buffer.toString();
      _buffer.clear();
      _buffer.write(text.substring(text.length - limit));
    }
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    _buffer.writeAll(objects, separator);
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

  /// The kept text. At most 2 x [limit] characters between trims, so cut
  /// to [limit] here.
  @override
  String toString() {
    String text = _buffer.toString();
    return text.length > limit ? text.substring(text.length - limit) : text;
  }
}
