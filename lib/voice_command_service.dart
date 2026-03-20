import 'package:speech_to_text/speech_to_text.dart' as stt;

class VoiceCommandService {
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool isListening = false;
  bool _manuallyStopped = false;
  Function(String)? _onCommand;
  
  Future<bool> initialize() async {
    return await _speech.initialize(
      onStatus: (status) {
  print("STATUS: $status");

  if (status == "listening") {
    isListening = true;
  } else {
    isListening = false;
  }
},
      onError: (error) {
  print("ERROR: ${error.errorMsg}");

  isListening = false;

  // 🔥 Restart automatically if not manually stopped
  if (!_manuallyStopped && _onCommand != null) {
  Future.delayed(const Duration(milliseconds: 300), () {
    startListening(_onCommand!);  // ✅ correct
  });
}
},
    );
  }

  void startListening(Function(String) onCommand) {
    if (isListening) return;

    _manuallyStopped = false;
    _onCommand = onCommand;
    isListening = true;

    _speech.listen(
  onResult: (result) {
    if (result.finalResult) {
      _onCommand?.call(result.recognizedWords);
    }
  },
  listenMode: stt.ListenMode.dictation,
  partialResults: false,
  listenFor: const Duration(minutes: 2),  // longer session
pauseFor: const Duration(seconds: 10),  // wait longer before timeout   // 🔥 Wait before timeout
  cancelOnError: false,
);
  }

  void _restartListening() {
    if (_manuallyStopped) return;

    isListening = false;

    Future.delayed(const Duration(milliseconds: 300), () {
      if (!_manuallyStopped && _onCommand != null) {
        startListening(_onCommand!);
      }
    });
  }

  void stopListening() {
    _manuallyStopped = true;   // 🔥 BLOCK restart
    isListening = false;
    _speech.stop();
  }
}
//updated voice