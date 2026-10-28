import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AudioRecorder startStream type check', () {
    final recorder = AudioRecorder();
    const config = RecordConfig(encoder: AudioEncoder.aacLc);
    expect(config.encoder, AudioEncoder.aacLc);
    recorder.dispose();
  });
}
