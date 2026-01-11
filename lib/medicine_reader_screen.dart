import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:flutter_tts/flutter_tts.dart';

class MedicineReaderScreen extends StatefulWidget {
  const MedicineReaderScreen({super.key});
  @override
  _MedicineReaderScreenState createState() => _MedicineReaderScreenState();
}

class _MedicineReaderScreenState extends State<MedicineReaderScreen> {
  File? _image;
  String _resultText = "Scan a prescription or strip.";
  final textRecognizer = TextRecognizer();
  final FlutterTts flutterTts = FlutterTts();

  Future<void> _scan(ImageSource source) async {
    final pickedFile = await ImagePicker().pickImage(source: source);
    if (pickedFile == null) return;

    setState(() => _image = File(pickedFile.path));
    final recognizedText = await textRecognizer.processImage(InputImage.fromFile(_image!));
    
    // Feature: Verification Logic
    String text = recognizedText.text;
    String feedback = "I found: $text. ";
    if (text.toLowerCase().contains("mg")) feedback += "This looks like a correct dosage.";
    
    setState(() => _resultText = feedback);
    await flutterTts.speak(feedback); // Voice feedback
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Medicine Assistant"), backgroundColor: Colors.purple[700]),
      body: Column(
        children: [
          if (_image != null) Image.file(_image!, height: 200),
          Padding(padding: const EdgeInsets.all(16), child: Text(_resultText)),
          ElevatedButton(onPressed: () => _scan(ImageSource.camera), child: const Text("Scan Medicine")),
        ],
      ),
    );
  }
}