/// Waits until [done] is true. Fails after 5 s.
Future<void> waitUntil(bool Function() done) async {
  Stopwatch watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > const Duration(seconds: 5)) {
      throw StateError('the condition was not true in 5 s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
