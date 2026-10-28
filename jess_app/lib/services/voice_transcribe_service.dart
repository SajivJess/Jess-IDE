import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'auth_api_service.dart';

class VoiceTranscribeService {
  final AudioRecorder _recorder;
  StreamSubscription<Uint8List>? _streamSub;
  final BytesBuilder _buffer = BytesBuilder();
  bool _isRecording = false;

  VoiceTranscribeService({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  bool get isRecording => _isRecording;

  /// Starts recording audio stream from the device microphone.
  /// Returns true if recording started successfully, false if permission denied or error.
  Future<bool> startRecording() async {
    try {
      if (_isRecording) return true;
      final hasPerm = await _recorder.hasPermission();
      if (!hasPerm) return false;

      _buffer.clear();
      final stream = await _recorder.startStream(
        const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 16000),
      );
      _streamSub = stream.listen((chunk) {
        _buffer.add(chunk);
      });
      _isRecording = true;
      return true;
    } catch (_) {
      _isRecording = false;
      return false;
    }
  }

  /// Stops audio recording, sends the captured audio bytes to the backend
  /// proxy which connects to Meta's Muse Voice Transcribe (muse-voice-transcribe-1.0),
  /// and returns the transcribed text.
  Future<String?> stopRecordingAndTranscribe({String? language}) async {
    try {
      if (!_isRecording) return null;
      await _streamSub?.cancel();
      _streamSub = null;
      await _recorder.stop();
      _isRecording = false;

      final bytes = _buffer.takeBytes();
      if (bytes.isEmpty) return null;

      return await transcribeAudio(
        audioBytes: bytes,
        filename: 'voice_input.m4a',
        language: language,
      );
    } catch (_) {
      _isRecording = false;
      return null;
    }
  }

  /// Cancels any active recording without transcribing.
  Future<void> cancelRecording() async {
    try {
      await _streamSub?.cancel();
      _streamSub = null;
      if (_isRecording) {
        await _recorder.stop();
      }
      _buffer.clear();
    } catch (_) {}
    _isRecording = false;
  }

  /// Transcribe recorded audio bytes by sending them to the Jess backend
  /// which securely mediates with Meta's Muse Voice Transcribe (muse-voice-transcribe-1.0).
  static Future<String?> transcribeAudio({
    required Uint8List audioBytes,
    String filename = 'voice_input.m4a',
    String? language,
  }) async {
    try {
      final token = await AuthApiService.getToken();
      final uri = Uri.parse('${AuthApiService.baseUrl}/voice/transcribe');

      final request = http.MultipartRequest('POST', uri);
      if (token != null && token.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $token';
      }

      final multipartFile = http.MultipartFile.fromBytes(
        'file',
        audioBytes,
        filename: filename,
      );
      request.files.add(multipartFile);

      if (language != null && language.isNotEmpty) {
        request.fields['language'] = language;
      }

      final streamedResponse = await request.send().timeout(const Duration(seconds: 45));
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['text'] as String?;
      } else {
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    cancelRecording();
    _recorder.dispose();
  }
}
