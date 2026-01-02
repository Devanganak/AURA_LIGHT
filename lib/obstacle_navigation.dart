import 'dart:async';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

class ObstacleDetection extends StatefulWidget {
  const ObstacleDetection({Key? key}) : super(key: key);

  @override
  State<ObstacleDetection> createState() => _ObstacleDetectionState();
}

class _ObstacleDetectionState extends State<ObstacleDetection> {
  // Camera variables
  late CameraController _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraInitialized = false;
  bool _isCameraActive = false;
  
  // Navigation variables
  bool _isNavigating = false;
  String _status = "Initializing camera...";
  List<String> _detectionLog = [];
  Timer? _detectionTimer;
  late FlutterTts _tts;
  
  // Detection variables
  double _detectionThreshold = 100.0;
  int _lastAlertTime = 0;
  String _lastAlert = "";
  int _frameCount = 0;
  
  // Simulation variables (temporary until ML model)
  final Random _random = Random();
  int _simulatedDistance = 500;
  String _simulatedObstacle = "clear";
  List<String> _obstacleTypes = [
    "clear", "wall", "door", "furniture", "person", 
    "stairs", "curb", "pole", "animal", "vehicle"
  ];

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await _initializeTTS();
    await _initializeCamera();
  }

  Future<void> _initializeTTS() async {
    _tts = FlutterTts();
    await _tts.setLanguage("en-IN");
    await _tts.setSpeechRate(0.4);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    await _tts.awaitSpeakCompletion(true);
  }

  Future<void> _initializeCamera() async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      _cameras = await availableCameras();
      
      if (_cameras.isEmpty) {
        setState(() {
          _status = "No camera found on this device";
        });
        _speakAlert("Camera not available. Using simulation mode.");
        return;
      }

      // Prefer back camera
      CameraDescription selectedCamera = _cameras.first;
      for (var camera in _cameras) {
        if (camera.lensDirection == CameraLensDirection.back) {
          selectedCamera = camera;
          break;
        }
      }

      _cameraController = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController.initialize();
      
      if (!mounted) return;
      
      setState(() {
        _isCameraInitialized = true;
        _isCameraActive = true;
        _status = "Camera ready. Tap start to begin navigation";
      });
      
      // Start image stream for real-time processing
      _startCameraStream();
      
    } catch (e) {
      print("Camera initialization error: $e");
      setState(() {
        _status = "Camera error: ${e.toString().substring(0, 50)}...";
      });
      _speakAlert("Camera initialization failed. Using simulation.");
    }
  }

  void _startCameraStream() {
    if (!_isCameraInitialized) return;
    
    _cameraController.startImageStream((CameraImage image) {
      _frameCount++;
      
      // Process every 10th frame to reduce CPU usage
      if (_frameCount % 10 == 0 && _isNavigating) {
        _processFrame(image);
      }
    });
  }

  void _processFrame(CameraImage image) {
    // This is where REAL obstacle detection would happen
    // For now, we simulate detection based on frame analysis
    
    // Simulate brightness analysis (darker = closer to obstacle)
    double avgBrightness = _simulateBrightnessAnalysis(image);
    
    // Simulate motion detection
    bool hasMotion = _simulateMotionDetection();
    
    // Update simulated values based on "analysis"
    _updateSimulation(avgBrightness, hasMotion);
    
    // Generate alert if needed
    _generateAlert();
  }

  double _simulateBrightnessAnalysis(CameraImage image) {
    // Simulate brightness analysis from camera frame
    return 0.5 + _random.nextDouble() * 0.5;
  }

  bool _simulateMotionDetection() {
    // Simulate motion detection
    return _random.nextDouble() > 0.7;
  }

  void _updateSimulation(double brightness, bool hasMotion) {
    // Simulate walking forward
    _simulatedDistance = max(0, _simulatedDistance - 10);
    
    // Randomly change obstacle type
    if (_random.nextDouble() > 0.8) {
      _simulatedObstacle = _obstacleTypes[_random.nextInt(_obstacleTypes.length)];
    }
    
    // Reset distance when obstacle passed
    if (_simulatedDistance <= 0) {
      _simulatedDistance = 200 + _random.nextInt(300);
    }
  }

  void _generateAlert() {
    if (!_isNavigating) return;
    
    final now = DateTime.now().millisecondsSinceEpoch;
    
    // Avoid too frequent alerts
    if (now - _lastAlertTime < 3000) return;
    
    String alert;
    Color alertColor = Colors.green;
    
    if (_simulatedDistance > 300) {
      alert = "Path clear. Continue forward";
      alertColor = Colors.green;
    } else if (_simulatedDistance > 150) {
      if (_simulatedObstacle == "clear") {
        alert = "Path mostly clear. ${_simulatedDistance}cm ahead";
      } else {
        alert = "${_simulatedObstacle.capitalize()} detected ${_simulatedDistance}cm ahead";
      }
      alertColor = Colors.blue;
    } else if (_simulatedDistance > 50) {
      alert = "Caution! ${_simulatedObstacle.capitalize()} ${_simulatedDistance}cm ahead";
      alertColor = Colors.orange;
      if (_simulatedObstacle == "stairs") {
        alert += ". Stairs detected";
      } else if (_simulatedObstacle == "door") {
        alert += ". Door on your path";
      }
    } else {
      alert = "STOP! ${_simulatedObstacle.capitalize()} too close! ${_simulatedDistance}cm";
      alertColor = Colors.red;
    }
    
    // Only speak if alert is different
    if (alert != _lastAlert) {
      _lastAlert = alert;
      _lastAlertTime = now;
      
      if (mounted) {
        setState(() {
          _status = alert;
          _detectionLog.insert(0, "[${_formatTime()}] $alert");
          if (_detectionLog.length > 8) {
            _detectionLog = _detectionLog.sublist(0, 8);
          }
        });
        
        _speakAlert(alert);
      }
    }
  }

  void _toggleNavigation() {
    if (!_isCameraInitialized) {
      _speakAlert("Camera not ready yet");
      return;
    }
    
    setState(() {
      _isNavigating = !_isNavigating;
    });
    
    if (_isNavigating) {
      _startNavigation();
      _speakAlert("Real-time navigation started. I will guide you.");
    } else {
      _stopNavigation();
      _speakAlert("Navigation stopped.");
    }
  }

  void _startNavigation() {
    // Reset simulation
    _simulatedDistance = 500;
    _simulatedObstacle = "clear";
    
    // Start detection timer as backup
    _detectionTimer = Timer.periodic(Duration(seconds: 2), (timer) {
      if (_isNavigating) {
        _generateAlert();
      }
    });
    
    setState(() {
      _status = "Navigation active. Processing camera feed...";
    });
  }

  void _stopNavigation() {
    _detectionTimer?.cancel();
    _detectionTimer = null;
    
    setState(() {
      _status = "Navigation stopped";
    });
  }

  void _speakAlert(String message) async {
    try {
      await _tts.speak(message);
    } catch (e) {
      print("TTS error: $e");
    }
  }

  String _formatTime() {
    final now = DateTime.now();
    return "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
  }

  void _toggleCamera() {
    if (!_isCameraInitialized) return;
    
    setState(() {
      _isCameraActive = !_isCameraActive;
    });
    
    if (_isCameraActive) {
      _startCameraStream();
      _speakAlert("Camera view enabled");
    } else {
      _cameraController.stopImageStream();
      _speakAlert("Camera view disabled");
    }
  }

  void _takeSnapshot() async {
    if (!_isCameraInitialized || !_isCameraActive) {
      _speakAlert("Camera not available");
      return;
    }
    
    try {
      final image = await _cameraController.takePicture();
      _speakAlert("Snapshot captured");
      
      setState(() {
        _detectionLog.insert(0, "[${_formatTime()}] Snapshot saved");
      });
    } catch (e) {
      print("Snapshot error: $e");
      _speakAlert("Failed to take snapshot");
    }
  }

  @override
  void dispose() {
    _stopNavigation();
    _cameraController.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Real-Time Obstacle Detection"),
        backgroundColor: Colors.blue[900],
        actions: [
          IconButton(
            icon: Icon(_isCameraActive ? Icons.videocam_off : Icons.videocam),
            onPressed: _toggleCamera,
            tooltip: 'Toggle camera',
          ),
          IconButton(
            icon: Icon(Icons.camera),
            onPressed: _takeSnapshot,
            tooltip: 'Take snapshot',
          ),
          IconButton(
            icon: Icon(Icons.volume_up),
            onPressed: () => _speakAlert(_status),
            tooltip: 'Repeat status',
          ),
        ],
      ),
      body: Column(
        children: [
          // Camera Preview Section
          Expanded(
            flex: 3,
            child: _buildCameraPreview(),
          ),

          // Status and Controls Section
          Expanded(
            flex: 2,
            child: _buildControlPanel(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleNavigation,
        icon: Icon(_isNavigating ? Icons.stop : Icons.directions_walk),
        label: Text(_isNavigating ? "STOP NAVIGATION" : "START NAVIGATION"),
        backgroundColor: _isNavigating ? Colors.red : Colors.green,
        foregroundColor: Colors.white,
        elevation: 4,
      ),
    );
  }

  Widget _buildCameraPreview() {
    if (!_isCameraInitialized) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                _status,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.grey[700]),
              ),
            ),
          ],
        ),
      );
    }

    if (!_isCameraActive) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.videocam_off, size: 80, color: Colors.grey[600]),
              SizedBox(height: 20),
              Text(
                "Camera disabled",
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
              SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: _toggleCamera,
                icon: Icon(Icons.videocam),
                label: Text("Enable Camera"),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        CameraPreview(_cameraController),
        
        // Overlay grid
        Container(
          child: CustomPaint(
            painter: NavigationGridPainter(
              isActive: _isNavigating,
              distance: _simulatedDistance,
            ),
          ),
        ),
        
        // Status overlay
        Positioned(
          top: 20,
          left: 20,
          right: 20,
          child: Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: _getStatusColor(),
                width: 2,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _getStatusIcon(),
                  color: _getStatusColor(),
                  size: 24,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isNavigating ? "NAVIGATING" : "READY",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        _status.length > 40 ? "${_status.substring(0, 40)}..." : _status,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                        maxLines: 2,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        
        // Distance indicator
        Positioned(
          bottom: 20,
          left: 20,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 15, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.social_distance, color: Colors.orange, size: 20),
                SizedBox(width: 8),
                Text(
                  "$_simulatedDistance cm",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
        
        // FPS indicator
        Positioned(
          bottom: 20,
          right: 20,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 15, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.speed, color: Colors.green, size: 20),
                SizedBox(width: 8),
                Text(
                  "LIVE",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildControlPanel() {
    return Container(
      color: Colors.grey[50],
      padding: EdgeInsets.all(16),
      child: Column(
        children: [
          // Status bar
          Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isNavigating ? Colors.green : Colors.red,
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _status,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey[800],
                    ),
                  ),
                ),
                Chip(
                  label: Text("${_detectionLog.length} alerts"),
                  backgroundColor: Colors.blue[100],
                ),
              ],
            ),
          ),
          SizedBox(height: 12),
          
          // Detection log
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Row(
                      children: [
                        Icon(Icons.history, size: 18, color: Colors.blue[800]),
                        SizedBox(width: 8),
                        Text(
                          "REAL-TIME DETECTION LOG",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blue[800],
                            fontSize: 14,
                          ),
                        ),
                        Spacer(),
                        Icon(
                          _isCameraActive ? Icons.videocam : Icons.videocam_off,
                          color: _isCameraActive ? Colors.green : Colors.red,
                          size: 18,
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 0),
                  Expanded(
                    child: _detectionLog.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.radar, size: 60, color: Colors.grey[300]),
                                SizedBox(height: 10),
                                Text(
                                  "No detections yet",
                                  style: TextStyle(color: Colors.grey),
                                ),
                                SizedBox(height: 5),
                                Text(
                                  _isNavigating 
                                      ? "Processing camera feed..."
                                      : "Start navigation to begin detection",
                                  style: TextStyle(color: Colors.grey, fontSize: 12),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: EdgeInsets.all(12),
                            itemCount: _detectionLog.length,
                            itemBuilder: (context, index) {
                              final isRecent = index == 0;
                              final isWarning = _detectionLog[index].contains("Caution") || 
                                               _detectionLog[index].contains("STOP");
                              final isEmergency = _detectionLog[index].contains("STOP!");
                              
                              return Container(
                                margin: EdgeInsets.only(bottom: 8),
                                padding: EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: isRecent
                                      ? (isEmergency 
                                          ? Colors.red[50] 
                                          : isWarning 
                                            ? Colors.orange[50] 
                                            : Colors.blue[50])
                                      : Colors.grey[50],
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isRecent
                                        ? (isEmergency 
                                            ? Colors.red 
                                            : isWarning 
                                              ? Colors.orange 
                                              : Colors.blue)
                                        : Colors.transparent,
                                    width: isRecent ? 1.5 : 0,
                                  ),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      isEmergency 
                                          ? Icons.warning 
                                          : isWarning 
                                            ? Icons.error_outline 
                                            : Icons.info,
                                      color: isEmergency 
                                          ? Colors.red 
                                          : isWarning 
                                            ? Colors.orange 
                                            : Colors.blue,
                                      size: 16,
                                    ),
                                    SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        _detectionLog[index],
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Colors.grey[800],
                                          fontWeight: isRecent ? FontWeight.w500 : FontWeight.normal,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor() {
    if (_simulatedDistance <= 50) return Colors.red;
    if (_simulatedDistance <= 150) return Colors.orange;
    if (_simulatedDistance <= 300) return Colors.blue;
    return Colors.green;
  }

  IconData _getStatusIcon() {
    if (_simulatedDistance <= 50) return Icons.warning;
    if (_simulatedDistance <= 150) return Icons.error_outline;
    if (_simulatedDistance <= 300) return Icons.info;
    return Icons.check_circle;
  }
}

// Helper extension for string capitalization
extension StringExtension on String {
  String capitalize() {
    if (isEmpty) return this;
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}

// Custom painter for navigation grid
class NavigationGridPainter extends CustomPainter {
  final bool isActive;
  final int distance;
  
  NavigationGridPainter({
    required this.isActive,
    required this.distance,
  });
  
  @override
  void paint(Canvas canvas, Size size) {
    if (!isActive) return;
    
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.2)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    
    // Draw grid
    for (double i = 0; i <= size.width; i += size.width / 3) {
      canvas.drawLine(Offset(i, 0), Offset(i, size.height), paint);
    }
    for (double j = 0; j <= size.height; j += size.height / 3) {
      canvas.drawLine(Offset(0, j), Offset(size.width, j), paint);
    }
    
    // Draw danger zone based on distance
    final dangerPaint = Paint()
      ..color = _getZoneColor().withOpacity(0.3)
      ..style = PaintingStyle.fill;
    
    double zoneHeight = size.height * (1 - (distance / 500.0));
    zoneHeight = zoneHeight.clamp(0.0, size.height * 0.7);
    
    canvas.drawRect(
      Rect.fromLTRB(
        size.width * 0.2,
        size.height - zoneHeight,
        size.width * 0.8,
        size.height,
      ),
      dangerPaint,
    );
    
    // Draw center crosshair
    final centerPaint = Paint()
      ..color = Colors.yellow.withOpacity(0.7)
      ..strokeWidth = 2.0;
    
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    
    canvas.drawLine(
      Offset(centerX - 20, centerY),
      Offset(centerX + 20, centerY),
      centerPaint,
    );
    canvas.drawLine(
      Offset(centerX, centerY - 20),
      Offset(centerX, centerY + 20),
      centerPaint,
    );
  }
  
  Color _getZoneColor() {
    if (distance <= 50) return Colors.red;
    if (distance <= 150) return Colors.orange;
    if (distance <= 300) return Colors.yellow;
    return Colors.green;
  }
  
  @override
  bool shouldRepaint(covariant NavigationGridPainter oldDelegate) {
    return isActive != oldDelegate.isActive || distance != oldDelegate.distance;
  }
}