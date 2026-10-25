import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/ui/features/downloads/download_batch.dart';

void main() {
  test('a batch counts its tracks as they finish and is over once none is left to come', () {
    final batch = DownloadBatch(name: 'Costa Norte', keys: {'a', 'b', 'c'});
    expect(batch.update({'a': BatchState.done, 'b': BatchState.waiting, 'c': BatchState.waiting}), isFalse);
    expect(batch.progress.value, closeTo(1 / 3, 1e-9));
    expect(batch.update({'a': BatchState.done, 'b': BatchState.done, 'c': BatchState.failed}), isTrue);
    expect((batch.done, batch.failed), (2, 1));
    expect(batch.progress.value, 1);
  });

  test('a track no longer listed holds nothing up and counts as neither done nor failed', () {
    final batch = DownloadBatch(name: 'Faro', keys: {'a', 'b'});
    expect(batch.update({'a': BatchState.done}), isTrue);
    expect((batch.done, batch.failed), (1, 0));
  });
}
