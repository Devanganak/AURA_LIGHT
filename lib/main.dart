import 'dart:io';
import 'package:auralight/medicine_reader_screen.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'obstacle_navigation.dart'; // Updated import for real-time navigation
import 'auth/login_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:firebase_auth/firebase_auth.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform,);
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Auralight - Visually Impaired Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      // Check the auth state here
      home: FirebaseAuth.instance.currentUser == null 
          ? const LoginScreen() 
          : const BillReaderScreen(),
    );
  }
}


class BillReaderScreen extends StatefulWidget {
  const BillReaderScreen({super.key});

  @override
  _BillReaderScreenState createState() => _BillReaderScreenState();
}

class _BillReaderScreenState extends State<BillReaderScreen> {
  final User? user = FirebaseAuth.instance.currentUser;

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
  title: const Text('Auralight Assistant'),
  centerTitle: true,
  backgroundColor: Colors.green[800],
  elevation: 4,
  actions: [
    // Real-Time Obstacle Detection
    IconButton(
      icon: const Icon(Icons.camera_alt_outlined),
      tooltip: 'Real-Time Obstacle Detection',
      onPressed: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ObstacleDetection(),
          ),
        );
      },
    ),

   
  ],
),


      drawer: Drawer(
        
        child: ListView(
          children: [
           UserAccountsDrawerHeader(
  decoration: BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Colors.green[800]!, Colors.green[600]!],
    ),
  ),
  currentAccountPicture: const CircleAvatar(
    backgroundColor: Colors.white,
    child: Icon(Icons.person, size: 40, color: Colors.green),
  ),
  accountName: Text(
    user?.email ?? "No Email",
    style: const TextStyle(fontWeight: FontWeight.bold),
  ),
  
  accountEmail: Text(
    "UID: ${user?.uid ?? "Not available"}",
    style: const TextStyle(fontSize: 12),
  ),
),

           ListTile(
  leading: Icon(Icons.receipt_long, color: Colors.green[700]),
  title: const Text(
    'Bill Reader',
    style: TextStyle(fontWeight: FontWeight.w500),
  ),
  onTap: () {
    Navigator.pop(context); // just close drawer
  },
  tileColor: Colors.green[50],
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(8),
  ),
),


            SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.directions_walk, color: Colors.blue[700]),
              title: Text('Real-Time Navigation',
                  style: TextStyle(fontWeight: FontWeight.w500)),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ObstacleDetection(),
                  ),
                );
              },
              tileColor: Colors.blue[50],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            // --- ADD THIS MEDICINE BUTTON HERE ---
// Inside your Drawer's ListView
ListTile(
  leading: const Icon(Icons.medication, color: Colors.purple),
  title: const Text('Medicine Reader', style: TextStyle(fontWeight: FontWeight.w500)),
  onTap: () {
    Navigator.pop(context); // Close the drawer
    Navigator.push(
      context, 
      MaterialPageRoute(builder: (_) => const MedicineReaderScreen())
    );
  },
  tileColor: Colors.purple[50],
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
),
const SizedBox(height: 12), // Spacing between buttons
            SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.settings, color: Colors.grey[700]),
              title: Text('Settings',
                  style: TextStyle(fontWeight: FontWeight.w500)),
              onTap: () {
                Navigator.pop(context);
                // Add settings screen here later
              },
            ),
            const SizedBox(height: 8),

ListTile(
  leading: const Icon(Icons.logout, color: Colors.red),
  title: const Text(
    'Logout',
    style: TextStyle(
      fontWeight: FontWeight.w600,
      color: Colors.red,
    ),
  ),
  onTap: () async {
    await FirebaseAuth.instance.signOut();

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  },
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(8),
  ),
),

            Divider(height: 40),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Text(
                'Features',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.text_fields, size: 18, color: Colors.grey),
              title: Text('Text Recognition',
                  style: TextStyle(fontSize: 14, color: Colors.grey[700])),
            ),
            ListTile(
              leading: Icon(Icons.volume_up, size: 18, color: Colors.grey),
              title: Text('Text-to-Speech',
                  style: TextStyle(fontSize: 14, color: Colors.grey[700])),
            ),
            ListTile(
              leading: Icon(Icons.camera, size: 18, color: Colors.grey),
              title: Text('Real-Time Camera',
                  style: TextStyle(fontSize: 14, color: Colors.grey[700])),
            ),
            ListTile(
              leading: Icon(Icons.warning, size: 18, color: Colors.grey),
              title: Text('Obstacle Detection',
                  style: TextStyle(fontSize: 14, color: Colors.grey[700])),
            ),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Bill Reader',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.green[900],
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Upload a bill to extract and hear text',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[600],
              ),
            ),
            SizedBox(height: 20),

            // Image Display Area
            Container(
              height: 250,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: _image != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        _image!,
                        height: 250,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    )
                  : Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.receipt_long,
                              size: 60, color: Colors.grey[400]),
                          SizedBox(height: 10),
                          Text(
                            'No bill image selected',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 16,
                            ),
                          ),
                          SizedBox(height: 5),
                          Text(
                            'Take a photo or choose from gallery',
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            SizedBox(height: 20),
            // --- MEDICINE MODULE DASHBOARD BUTTON ---
SizedBox(
  width: double.infinity,
  child: ElevatedButton.icon(
    icon: const Icon(Icons.health_and_safety, size: 22),
    label: const Text('MEDICINE PRESCRIPTION READER'),
    onPressed: () {
      Navigator.push(
        context, 
        MaterialPageRoute(builder: (_) => const MedicineReaderScreen())
      );
    },
    style: ElevatedButton.styleFrom(
      padding: const EdgeInsets.symmetric(vertical: 16),
      backgroundColor: Colors.purple[700], 
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      elevation: 5,
    ),
  ),
),
const SizedBox(height: 12),

            // Extracted Text Area
            Expanded(
              child: Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey[300]!),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.text_fields, color: Colors.green[700]),
                        SizedBox(width: 8),
                        Text(
                          'Extracted Text',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.green[900],
                          ),
                        ),
                        Spacer(),
                        if (_extractedText.isNotEmpty)
                          IconButton(
                            icon: Icon(Icons.volume_up, color: Colors.blue),
                            onPressed: _speakText,
                            tooltip: 'Read aloud',
                          ),
                      ],
                    ),
                    SizedBox(height: 12),
                    Expanded(
                      child: _isLoading
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  CircularProgressIndicator(
                                    color: Colors.green,
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    'Extracting text...',
                                    style: TextStyle(color: Colors.grey[600]),
                                  ),
                                ],
                              ),
                            )
                          : SingleChildScrollView(
                              child: Text(
                                _extractedText.isEmpty
                                    ? 'Upload a bill to extract text. The extracted text will appear here.'
                                    : _extractedText,
                                style: TextStyle(
                                  fontSize: 15,
                                  color: Colors.grey[800],
                                  height: 1.5,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 20),

            // Quick Action Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: Icon(Icons.camera_alt, size: 20),
                    label: Text("Camera"),
                    onPressed: () => _pickImage(ImageSource.camera),
                    style: ElevatedButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: Colors.green[700],
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: Icon(Icons.photo_library, size: 20),
                    label: Text("Gallery"),
                    onPressed: () => _pickImage(ImageSource.gallery),
                    style: ElevatedButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: Colors.blue[700],
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 12),

            // Navigation Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: Icon(Icons.camera, size: 22),
                label: Text('REAL-TIME OBSTACLE NAVIGATION'),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ObstacleDetection(),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.orange[700],
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  elevation: 4,
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (_extractedText.isNotEmpty) {
            _speakText();
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('No text to read. Upload a bill first.'),
                backgroundColor: Colors.orange,
              ),
            );
          }
        },
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        tooltip: 'Read extracted text',
        child: Icon(Icons.volume_up),
      ),
    );
  }
}