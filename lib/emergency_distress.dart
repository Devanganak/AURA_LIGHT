import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

class EmergencyDistressService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  final FlutterTts _tts = FlutterTts();

  // Emergency contacts
  final List<String> emergencyContacts = [
    "9961142944",  // Primary contact
    "9123456789",  // Secondary contact
  ];

  Future<void> startListening() async {
    // Check and request microphone permission
    var status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
    }
    
    if (status != PermissionStatus.granted) {
      print("Microphone permission denied");
      return;
    }

    bool available = await _speech.initialize(
      onStatus: (status) => print("Status: $status"),
      onError: (error) => print("Error: $error"),
    );

    if (!available) {
      print("Speech recognition not available");
      return;
    }

    if (!_isListening) {
      _isListening = true;
      print("🆘 Emergency listening started");

      await _speech.listen(
        onResult: (result) {
          final spokenText = result.recognizedWords.toLowerCase();
          print("Heard: $spokenText");

          // Trigger on emergency keywords
          if (spokenText.contains("help") ||
              spokenText.contains("emergency") ||
              spokenText.contains("sos") ||
              spokenText.contains("danger") ||
              spokenText.contains("救命") || // Chinese: help
              spokenText.contains("ayuda")) { // Spanish: help
            print("🆘 Emergency keyword detected!");
            _triggerEmergencyResponse();
          }
        },
        listenMode: stt.ListenMode.confirmation,
        cancelOnError: true,
        partialResults: false,
      );
    }
  }

  void stopListening() {
    if (_isListening) {
      _speech.stop();
      _isListening = false;
      print("🆘 Emergency listening stopped");
    }
  }

  Future<void> _triggerEmergencyResponse() async {
    stopListening(); // Stop listening to prevent multiple triggers
    
    // Speak confirmation
    await _tts.speak("Emergency detected! Sending alerts to your contacts.");
    
    // Send SMS to all emergency contacts
    for (String contact in emergencyContacts) {
      await _sendEmergencySMS(contact);
    }
    
    // Restart listening after a delay
    Future.delayed(Duration(seconds: 10), () {
      if (!_isListening) {
        startListening();
      }
    });
  }

  // Public method to manually trigger emergency
  Future<void> sendEmergencySMS() async {
    await _tts.speak("Sending emergency alert");
    
    for (String contact in emergencyContacts) {
      await _sendEmergencySMS(contact);
    }
  }

  Future<void> _sendEmergencySMS(String phoneNumber) async {
    final Uri smsUri = Uri(
      scheme: 'sms',
      path: phoneNumber,
      queryParameters: {
        'body': '🆘 EMERGENCY ALERT from Auralight App!\n'
                'I need immediate assistance.\n'
                'Please check on me as soon as possible.\n'
                'Sent via Auralight Visual Assistant App',
      },
    );

    try {
      if (await canLaunchUrl(smsUri)) {
        await launchUrl(smsUri);
        print("📱 Emergency SMS sent to $phoneNumber");
      } else {
        print("❌ Could not launch SMS for $phoneNumber");
        // Alternative: Try launching without parameters
        final Uri altSmsUri = Uri.parse('sms:$phoneNumber');
        if (await canLaunchUrl(altSmsUri)) {
          await launchUrl(altSmsUri);
        }
      }
    } catch (e) {
      print("❌ Error sending SMS: $e");
    }
  }

  // Getter to check if listening is active
  bool get isListening => _isListening;

  // Cleanup method
  void dispose() {
    stopListening();
    _tts.stop();
  }
}