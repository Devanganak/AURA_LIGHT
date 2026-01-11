import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'obstacle_navigation.dart';
import 'emergency_distress.dart'; // 🆘 EMERGENCY FEATURE

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Auralight - Visually Impaired Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: BillReaderScreen(),
      routes: {
        '/navigation': (context) => ObstacleDetection(),
      },
    );
  }
}

class BillReaderScreen extends StatefulWidget {
  @override
  _BillReaderScreenState createState() => _BillReaderScreenState();
}

class _BillReaderScreenState extends State<BillReaderScreen> {
  // 🆘 EMERGENCY FEATURE
  final EmergencyDistressService emergencyService = EmergencyDistressService();

  File? _image;
  String _extractedText = "";
  final picker = ImagePicker();
  final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final FlutterTts flutterTts = FlutterTts();
  bool _isLoading = false;
  bool _emergencyActive = true; // Track emergency listening status

  // 🆘 START LISTENING WHEN APP OPENS
  @override
  void initState() {
    super.initState();
    emergencyService.startListening();
  }

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
    final RecognizedText recognizedText =
        await textRecognizer.processImage(inputImage);

    setState(() {
      _extractedText = recognizedText.text;
      _isLoading = false;
    });
  }

  Future<void> _speakText() async {
    if (_extractedText.isEmpty) return;
    await flutterTts.setLanguage("en-IN");
    await flutterTts.setPitch(1.0);
    await flutterTts.setSpeechRate(0.4);
    await flutterTts.speak(_extractedText);
  }

  // 🆘 EMERGENCY BUTTON FUNCTION
  void _triggerEmergency() {
    emergencyService.sendEmergencySMS();
    
    // Speak confirmation
    flutterTts.speak("Emergency alert sent to contacts");
    
    // Show visual feedback
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🆘 Emergency SMS Sent!'),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 3),
      ),
    );
  }

  // 🆘 TOGGLE EMERGENCY LISTENING
  void _toggleEmergencyListening() {
    setState(() {
      _emergencyActive = !_emergencyActive;
    });
    
    if (_emergencyActive) {
      emergencyService.startListening();
      flutterTts.speak("Emergency listening activated");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Emergency listening activated'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      emergencyService.stopListening();
      flutterTts.speak("Emergency listening deactivated");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⏸️ Emergency listening paused'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  @override
  void dispose() {
    textRecognizer.close();
    flutterTts.stop();
    emergencyService.stopListening(); // 🆘 Stop emergency listening
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Auralight Assistant'),
        centerTitle: true,
        backgroundColor: Colors.green[800],
        elevation: 4,
        actions: [
          IconButton(
            icon: Icon(Icons.camera_alt_outlined),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ObstacleDetection(),
                ),
              );
            },
            tooltip: 'Real-Time Obstacle Detection',
          ),
          // 🆘 EMERGENCY BUTTON IN APP BAR
          IconButton(
            icon: Icon(Icons.emergency, color: Colors.red),
            onPressed: _triggerEmergency,
            tooltip: 'Send Emergency Alert',
          ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Colors.green[800]!, Colors.green[600]!],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.visibility_off, size: 40, color: Colors.white),
                  SizedBox(height: 10),
                  Text(
                    'Auralight',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Your Visual Assistant',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.9), fontSize: 14),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: Icon(Icons.receipt_long),
              title: Text('Bill Reader'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: Icon(Icons.directions_walk),
              title: Text('Real-Time Navigation'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ObstacleDetection(),
                  ),
                );
              },
            ),
            // 🆘 EMERGENCY OPTION IN DRAWER
            Divider(),
            ListTile(
              leading: Icon(Icons.emergency, color: Colors.red),
              title: Text('Emergency Distress', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _triggerEmergency();
              },
            ),
            ListTile(
              leading: Icon(_emergencyActive ? Icons.mic_off : Icons.mic, 
                  color: _emergencyActive ? Colors.orange : Colors.green),
              title: Text(_emergencyActive ? 'Pause Emergency Listening' : 'Activate Emergency Listening'),
              subtitle: Text('Voice command: Say "HELP"'),
              onTap: _toggleEmergencyListening,
            ),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 🆘 EMERGENCY STATUS INDICATOR
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _emergencyActive ? Colors.red.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _emergencyActive ? Colors.red : Colors.grey,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _emergencyActive ? Icons.security : Icons.security_outlined,
                    color: _emergencyActive ? Colors.red : Colors.grey,
                    size: 20,
                  ),
                  SizedBox(width: 8),
                  Text(
                    _emergencyActive ? '🆘 EMERGENCY LISTENING ACTIVE' : 'Emergency Listening Paused',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _emergencyActive ? Colors.red : Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 20),
            
            // EXISTING IMAGE PICKER BUTTONS
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  icon: Icon(Icons.camera_alt),
                  label: Text('Take Photo'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green[700],
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                  ),
                  onPressed: () => _pickImage(ImageSource.camera),
                ),
                ElevatedButton.icon(
                  icon: Icon(Icons.photo_library),
                  label: Text('Gallery'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue[700],
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                  ),
                  onPressed: () => _pickImage(ImageSource.gallery),
                ),
              ],
            ),
            SizedBox(height: 20),
            
            // IMAGE PREVIEW
            if (_image != null)
              Expanded(
                child: Column(
                  children: [
                    Text(
                      'Captured Image:',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    SizedBox(height: 10),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Image.file(_image!, fit: BoxFit.contain),
                      ),
                    ),
                  ],
                ),
              ),
            
            // LOADING INDICATOR
            if (_isLoading)
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 10),
                    Text('Extracting text...'),
                  ],
                ),
              ),
            
            // EXTRACTED TEXT
            if (_extractedText.isNotEmpty && !_isLoading)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Extracted Text:',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    SizedBox(height: 10),
                    Expanded(
                      child: Container(
                        padding: EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.green),
                        ),
                        child: SingleChildScrollView(
                          child: Text(
                            _extractedText,
                            style: TextStyle(fontSize: 16),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            
            if (_image == null && _extractedText.isEmpty && !_isLoading)
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.receipt_long,
                      size: 80,
                      color: Colors.grey[400],
                    ),
                    SizedBox(height: 20),
                    Text(
                      'No image selected',
                      style: TextStyle(
                        fontSize: 18,
                        color: Colors.grey[600],
                      ),
                    ),
                    Text(
                      'Take a photo or choose from gallery',
                      style: TextStyle(
                        color: Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ),
            
            SizedBox(height: 20),
          ],
        ),
      ),
      // EXISTING FLOATING ACTION BUTTONS
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            FloatingActionButton(
              onPressed: () {
                if (_extractedText.isNotEmpty) {
                  _speakText();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('No text to read'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                }
              },
              child: Icon(Icons.volume_up),
              tooltip: 'Read Text Aloud',
            ),
            // 🆘 EMERGENCY FLOATING BUTTON
            FloatingActionButton(
              onPressed: _triggerEmergency,
              backgroundColor: Colors.red,
              child: Icon(Icons.emergency),
              tooltip: 'Emergency Distress',
            ),
          ],
        ),
      ),
    );
  }
}