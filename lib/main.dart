import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  runApp(BillReaderApp());
}

class BillReaderApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bill Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
      ),
      home: BillReaderScreen(),
    );
  }
}

class BillReaderScreen extends StatefulWidget {
  @override
  _BillReaderScreenState createState() => _BillReaderScreenState();
}

class _BillReaderScreenState extends State<BillReaderScreen> {
  File? _image;
  String _extractedText = "";
  final picker = ImagePicker();
  final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final FlutterTts flutterTts = FlutterTts();
  bool _isLoading = false;

  Future<void> _pickImage(ImageSource source) async {
    final pickedFile = await picker.pickImage(source: source);
    if (pickedFile != null) {
      setState(() {
        _image = File(pickedFile.path);
        _extractedText = "";
      });
      _extractText();
    }
  }

  Future<void> _extractText() async {
    if (_image == null) return;
    setState(() => _isLoading = true);

    final inputImage = InputImage.fromFile(_image!);
    final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);

    setState(() {
      _extractedText = recognizedText.text;
      _isLoading = false;
    });
  }

  Future<void> _speakText() async {
    if (_extractedText.isEmpty) return;
    await flutterTts.setLanguage("en-IN");
    await flutterTts.setPitch(1.0);
    await flutterTts.speak(_extractedText);
  }

  @override
  void dispose() {
    textRecognizer.close();
    flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Bill Reader'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            if (_image != null)
              Image.file(_image!, height: 250)
            else
              Container(
                height: 250,
                width: double.infinity,
                color: Colors.grey[200],
                child: Center(child: Text('No image selected')),
              ),
            const SizedBox(height: 20),
            if (_isLoading)
              CircularProgressIndicator()
            else
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    _extractedText.isEmpty
                        ? 'Upload a bill to extract text'
                        : _extractedText,
                    style: TextStyle(fontSize: 16),
                  ),
                ),
              ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                ElevatedButton.icon(
                  icon: Icon(Icons.camera_alt),
                  label: Text("Camera"),
                  onPressed: () => _pickImage(ImageSource.camera),
                ),
                ElevatedButton.icon(
                  icon: Icon(Icons.image),
                  label: Text("Gallery"),
                  onPressed: () => _pickImage(ImageSource.gallery),
                ),
                ElevatedButton.icon(
                  icon: Icon(Icons.volume_up),
                  label: Text("Read Aloud"),
                  onPressed: _speakText,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
