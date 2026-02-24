import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:auralight/medicine_reader_screen.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';
import 'package:tesseract_ocr/ocr_engine_config.dart';
import 'obstacle_navigation.dart'; // Updated import for real-time navigation
import 'auth/login_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'settings_screen.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
final FlutterLocalNotificationsPlugin _globalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();
String? _pendingMedicineReminderPayload;
const String _ocrVariantHandwriting = 'handwriting';
const String _ocrVariantHandwritingSoft = 'handwriting_soft';
const String _ocrVariantHandwritingBinary = 'handwriting_binary';
const String _ocrVariantBlueInk = 'blue_ink';
const String _ocrVariantHandwritingSharpen = 'handwriting_sharpen';
const String _ocrVariantHandwritingCrop = 'handwriting_crop';
const String _ocrVariantNewspaper = 'newspaper';
const String _ocrVariantUpscaled = 'upscaled';
const bool _enableMalayalamTesseractFallback = bool.fromEnvironment(
  'AURALIGHT_ENABLE_MALAYALAM_TESSERACT',
  defaultValue: true,
);
const String _tessdataConfigAssetPath = 'assets/tessdata_config.json';
const String _malayalamTessDataAssetPath = 'assets/tessdata/mal.traineddata';

img.Image _limitImageSizeForOcr(img.Image source, {int maxDimension = 1700}) {
  final largestSide = math.max(source.width, source.height);
  if (largestSide <= maxDimension) {
    return img.Image.from(source);
  }

  final scale = maxDimension / largestSide;
  return img.copyResize(
    source,
    width: (source.width * scale).round(),
    height: (source.height * scale).round(),
    interpolation: img.Interpolation.linear,
  );
}

Uint8List? _buildOcrVariantBytes(Map<String, dynamic> payload) {
  final sourceBytes = payload['bytes'];
  final variant = payload['variant'];
  if (sourceBytes is! Uint8List || variant is! String) return null;

  final decoded = img.decodeImage(sourceBytes);
  if (decoded == null) return null;

  var working = img.bakeOrientation(decoded);
  working = _limitImageSizeForOcr(working);

  switch (variant) {
    case _ocrVariantHandwritingSoft:
      img.grayscale(working);
      img.gaussianBlur(working, radius: 1);
      img.normalize(working, min: 0, max: 255);
      img.adjustColor(working, contrast: 1.18, brightness: 1.08, gamma: 0.92);
      break;
    case _ocrVariantHandwriting:
      img.grayscale(working);
      img.normalize(working, min: 0, max: 255);
      img.adjustColor(working, contrast: 1.30, brightness: 1.06, gamma: 0.95);
      break;
    case _ocrVariantHandwritingBinary:
      img.grayscale(working);
      img.normalize(working, min: 0, max: 255);
      img.adjustColor(working, contrast: 1.45, brightness: 1.10);
      img.luminanceThreshold(working, threshold: 0.57);
      break;
    case _ocrVariantBlueInk:
      for (final p in working) {
        final rgAverage = (p.r + p.g) / 2.0;
        final blueDelta = (p.b - rgAverage).clamp(0, 255).toDouble();
        final inkStrength = (blueDelta * 3.1).clamp(0.0, 255.0);
        final value = (255.0 - inkStrength).clamp(0.0, 255.0);
        p
          ..r = value
          ..g = value
          ..b = value;
      }
      img.gaussianBlur(working, radius: 1);
      img.normalize(working, min: 0, max: 255);
      img.adjustColor(working, contrast: 1.35, brightness: 1.05);
      img.luminanceThreshold(working, threshold: 0.64);
      break;
    case _ocrVariantHandwritingSharpen:
      img.grayscale(working);
      img.normalize(working, min: 0, max: 255);
      img.adjustColor(working, contrast: 1.28, brightness: 1.05, gamma: 0.95);
      img.convolution(
        working,
        filter: const [0, -1, 0, -1, 5, -1, 0, -1, 0],
      );
      break;
    case _ocrVariantHandwritingCrop:
      final marginX = (working.width * 0.045).round();
      final marginY = (working.height * 0.055).round();
      if (working.width > (marginX * 2 + 200) &&
          working.height > (marginY * 2 + 200)) {
        working = img.copyCrop(
          working,
          x: marginX,
          y: marginY,
          width: working.width - (marginX * 2),
          height: working.height - (marginY * 2),
        );
      }
      img.grayscale(working);
      img.normalize(working, min: 0, max: 255);
      img.adjustColor(working, contrast: 1.30, brightness: 1.06, gamma: 0.95);
      break;
    case _ocrVariantNewspaper:
      img.grayscale(working);
      img.normalize(working, min: 0, max: 255);
      img.luminanceThreshold(working, threshold: 0.60);
      break;
    case _ocrVariantUpscaled:
      if (working.width >= 1400 || working.height >= 1400) return null;
      final targetWidth = math.min(1800, (working.width * 1.6).round());
      working = img.copyResize(
        working,
        width: targetWidth,
        interpolation: img.Interpolation.linear,
      );
      break;
    default:
      return null;
  }

  return img.encodeJpg(working, quality: 90);
}

Future<void> _initGlobalNotificationRouting() async {
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initSettings =
      InitializationSettings(android: androidSettings);

  final androidNotifications =
      _globalNotificationsPlugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidNotifications?.requestNotificationsPermission();
  await androidNotifications?.requestFullScreenIntentPermission();
  final canScheduleExact =
      await androidNotifications?.canScheduleExactNotifications() ?? false;
  if (!canScheduleExact) {
    await androidNotifications?.requestExactAlarmsPermission();
  }

  await _globalNotificationsPlugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse: _handleGlobalNotificationResponse,
  );

  final launchDetails =
      await _globalNotificationsPlugin.getNotificationAppLaunchDetails();
  final launchResponse = launchDetails?.notificationResponse;
  if ((launchDetails?.didNotificationLaunchApp ?? false) &&
      launchResponse != null) {
    _handleGlobalNotificationResponse(launchResponse);
  }
}

void _handleGlobalNotificationResponse(NotificationResponse response) {
  if (response.actionId != null && response.actionId!.isNotEmpty) return;
  final payload = response.payload;
  if (payload == null || payload.isEmpty) return;

  try {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) return;
    final reminder = Map<String, dynamic>.from(decoded);
    if (!reminder.containsKey('name')) return;
  } catch (_) {
    return;
  }

  _pendingMedicineReminderPayload = payload;
  _openPendingMedicineReminderScreen();
}

void _openPendingMedicineReminderScreen() {
  final payload = _pendingMedicineReminderPayload;
  final navigator = appNavigatorKey.currentState;
  if (payload == null || navigator == null) return;
  if (FirebaseAuth.instance.currentUser == null) return;

  _pendingMedicineReminderPayload = null;
  navigator.push(
    MaterialPageRoute(
      builder: (_) => MedicineReaderScreen(initialReminderPayload: payload),
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await AppSettings.load();
  await _initGlobalNotificationRouting();
  runApp(const MyApp());
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _openPendingMedicineReminderScreen();
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final launchReminderPayload = _pendingMedicineReminderPayload;
    if (user != null && launchReminderPayload != null) {
      _pendingMedicineReminderPayload = null;
    }

    final baseTextTheme = ThemeData.light().textTheme;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0A5A36),
      brightness: Brightness.light,
    ).copyWith(
      primary: const Color(0xFF0A5A36),
      onPrimary: Colors.white,
      secondary: const Color(0xFF0C6B60),
      onSecondary: Colors.white,
      surface: Colors.white,
      onSurface: const Color(0xFF111827),
    );

    return ValueListenableBuilder<double>(
      valueListenable: AppSettings.textScale,
      builder: (context, appTextScale, _) {
        return MaterialApp(
          navigatorKey: appNavigatorKey,
          title: 'Auralight - Visually Impaired Assistant',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: colorScheme,
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(0xFFF3F8F6),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF0A5A36),
              foregroundColor: Colors.white,
              centerTitle: true,
              titleTextStyle: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
            textTheme: baseTextTheme.copyWith(
              headlineLarge: baseTextTheme.headlineLarge?.copyWith(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                color: const Color(0xFF111827),
              ),
              headlineMedium: baseTextTheme.headlineMedium?.copyWith(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: const Color(0xFF111827),
              ),
              titleLarge: baseTextTheme.titleLarge?.copyWith(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: const Color(0xFF111827),
              ),
              titleMedium: baseTextTheme.titleMedium?.copyWith(
                fontSize: 21,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF111827),
              ),
              bodyLarge: baseTextTheme.bodyLarge?.copyWith(
                fontSize: 20,
                height: 1.45,
                color: const Color(0xFF111827),
              ),
              bodyMedium: baseTextTheme.bodyMedium?.copyWith(
                fontSize: 18,
                height: 1.45,
                color: const Color(0xFF111827),
              ),
              bodySmall: baseTextTheme.bodySmall?.copyWith(
                fontSize: 16,
                height: 1.4,
                color: const Color(0xFF374151),
              ),
              labelLarge: baseTextTheme.labelLarge?.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(64, 58),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                textStyle: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            outlinedButtonTheme: OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(64, 58),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                side: const BorderSide(width: 2.2),
                textStyle: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            iconButtonTheme: IconButtonThemeData(
              style: IconButton.styleFrom(
                minimumSize: const Size(56, 56),
                iconSize: 30,
              ),
            ),
            listTileTheme: const ListTileThemeData(
              minVerticalPadding: 12,
              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              iconColor: Color(0xFF0A5A36),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:
                    const BorderSide(color: Color(0xFF0A5A36), width: 1.6),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:
                    const BorderSide(color: Color(0xFF0A5A36), width: 2.4),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              labelStyle:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              hintStyle: const TextStyle(fontSize: 17),
            ),
            cardTheme: CardTheme(
              elevation: 1.5,
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: Color(0xFFE2E8F0), width: 1),
              ),
            ),
            floatingActionButtonTheme: const FloatingActionButtonThemeData(
              backgroundColor: Color(0xFF0A5A36),
              foregroundColor: Colors.white,
            ),
          ),
          builder: (context, child) {
            final media = MediaQuery.of(context);
            final systemScale = media.textScaler.scale(1.0);
            final effectiveScale =
                (systemScale * appTextScale).clamp(0.9, 2.3).toDouble();
            return MediaQuery(
              data: media.copyWith(
                textScaler: TextScaler.linear(effectiveScale),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: user == null
              ? const LoginScreen()
              : launchReminderPayload != null
                  ? MedicineReaderScreen(
                      initialReminderPayload: launchReminderPayload,
                    )
                  : const BillReaderScreen(),
        );
      },
    );
  }
}

class BillReaderScreen extends StatefulWidget {
  const BillReaderScreen({super.key});

  @override
  State<BillReaderScreen> createState() => _BillReaderScreenState();
}

class _OcrCandidate {
  const _OcrCandidate({
    required this.text,
    required this.score,
    required this.label,
  });

  final String text;
  final double score;
  final String label;
}

class _BillReaderScreenState extends State<BillReaderScreen> {
  final User? user = FirebaseAuth.instance.currentUser;

  File? _image;
  String _extractedText = "";
  final picker = ImagePicker();
  final TextRecognizer _latinTextRecognizer =
      TextRecognizer(script: TextRecognitionScript.latin);
  final TextRecognizer _indicTextRecognizer =
      TextRecognizer(script: TextRecognitionScript.devanagiri);
  final FlutterTts flutterTts = FlutterTts();
  bool _isLoading = false;
  bool _isSpeaking = false;
  bool _isPaused = false;
  double _speechRate = 0.4;
  int _ocrSessionId = 0;
  bool? _isMalayalamTessdataReady;
  static final RegExp _ocrLetterPattern =
      RegExp(r'[A-Za-z\u0900-\u097F\u0D00-\u0D7F]');
  static final RegExp _digitPattern = RegExp(r'[0-9]');
  static final RegExp _malayalamPattern = RegExp(r'[\u0D00-\u0D7F]');

  String get _voiceStatusLabel {
    if (_isPaused) return 'Paused';
    if (_isSpeaking) return 'Reading';
    return 'Stopped';
  }

  String get _voiceStatusHint {
    if (_isPaused) {
      return 'Tap Resume to continue from the paused position.';
    }
    if (_isSpeaking) {
      return 'Voice reading is active. Use Pause or Stop when needed.';
    }
    return 'Tap Start to read the extracted text aloud.';
  }

  IconData get _voiceStatusIcon {
    if (_isPaused) return Icons.pause_circle_filled;
    if (_isSpeaking) return Icons.volume_up_rounded;
    return Icons.stop_circle_outlined;
  }

  Color get _voiceStatusColor {
    if (_isPaused) return const Color(0xFFB45309);
    if (_isSpeaking) return const Color(0xFF065F46);
    return const Color(0xFF475569);
  }

  Color get _voiceStatusBackground {
    if (_isPaused) return const Color(0xFFFEF3C7);
    if (_isSpeaking) return const Color(0xFFD1FAE5);
    return const Color(0xFFE2E8F0);
  }

  Widget _buildVoiceStatusCard() {
    return Semantics(
      liveRegion: true,
      label: 'Voice reading status: $_voiceStatusLabel. $_voiceStatusHint',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: _voiceStatusBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _voiceStatusColor, width: 2),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(_voiceStatusIcon, color: _voiceStatusColor, size: 34),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Voice Status: $_voiceStatusLabel',
                    style: TextStyle(
                      color: _voiceStatusColor,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _voiceStatusHint,
                    style: const TextStyle(
                      color: Color(0xFF111827),
                      fontSize: 16,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _applySpeechRate({bool restartIfSpeaking = false}) async {
    await flutterTts.setSpeechRate(_speechRate);
    if (restartIfSpeaking &&
        _isSpeaking &&
        !_isPaused &&
        _extractedText.isNotEmpty) {
      // Keep current reading position; do not restart from beginning.
      await flutterTts.pause();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await flutterTts.speak(_extractedText);
    }
  }

  void _onSpeechRateChanged(double value) {
    setState(() => _speechRate = value);
    // Apply base rate immediately, but avoid repeated restart calls while dragging.
    _applySpeechRate();
  }

  Future<void> _setSpeechRatePreset(double value) async {
    setState(() => _speechRate = value);
    await _applySpeechRate(restartIfSpeaking: true);
  }

  Widget _buildSpeechRateCard() {
    final speedPercent = (_speechRate * 100).round();
    return Semantics(
      liveRegion: true,
      label: 'Voice reading speed $speedPercent percent',
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.speed_rounded, color: Color(0xFF0B3A8A)),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Reading Speed',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  Text(
                    '$speedPercent%',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0B3A8A),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Slider(
                value: _speechRate,
                min: 0.2,
                max: 0.8,
                divisions: 12,
                label: '$speedPercent%',
                onChanged: _onSpeechRateChanged,
                onChangeEnd: (value) => _setSpeechRatePreset(value),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildSpeedPresetChip('Slow', 0.3),
                  _buildSpeedPresetChip('Normal', 0.4),
                  _buildSpeedPresetChip('Fast', 0.55),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSpeedPresetChip(String label, double value) {
    final isSelected = (_speechRate - value).abs() < 0.01;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => _setSpeechRatePreset(value),
      selectedColor: const Color(0xFFDBEAFE),
      side: const BorderSide(color: Color(0xFF93C5FD)),
    );
  }

  @override
  void initState() {
    super.initState();
    _configureTtsHandlers();
    Future<void>.microtask(() => _applySpeechRate());
  }

  void _configureTtsHandlers() {
    flutterTts.setStartHandler(() {
      if (!mounted) return;
      setState(() {
        _isSpeaking = true;
        _isPaused = false;
      });
    });

    flutterTts.setPauseHandler(() {
      if (!mounted) return;
      setState(() {
        _isSpeaking = true;
        _isPaused = true;
      });
    });

    flutterTts.setContinueHandler(() {
      if (!mounted) return;
      setState(() {
        _isSpeaking = true;
        _isPaused = false;
      });
    });

    flutterTts.setCompletionHandler(() {
      if (!mounted) return;
      setState(() {
        _isSpeaking = false;
        _isPaused = false;
      });
    });

    flutterTts.setCancelHandler(() {
      if (!mounted) return;
      setState(() {
        _isSpeaking = false;
        _isPaused = false;
      });
    });

    flutterTts.setErrorHandler((_) {
      if (!mounted) return;
      setState(() {
        _isSpeaking = false;
        _isPaused = false;
      });
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    final pickedFile = await picker.pickImage(source: source);
    if (pickedFile != null) {
      if (_isSpeaking || _isPaused) {
        await _stopSpeaking();
      }
      setState(() {
        _image = File(pickedFile.path);
        _extractedText = "";
      });
      _extractText();
    }
  }

  Future<void> _extractText() async {
    final sourceImage = _image;
    if (sourceImage == null) return;
    final requestId = ++_ocrSessionId;
    setState(() {
      _isLoading = true;
    });

    try {
      final bestResult = await _runSmartOcr(sourceImage);
      if (!mounted || requestId != _ocrSessionId) return;
      setState(() {
        _extractedText = bestResult.text;
      });
    } catch (_) {
      if (!mounted || requestId != _ocrSessionId) return;
      setState(() {
        _extractedText =
            'Unable to read this image clearly. Try a sharper photo with better lighting.';
      });
    } finally {
      if (mounted && requestId == _ocrSessionId) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<_OcrCandidate> _runSmartOcr(File sourceFile) async {
    final sourceBytes = await sourceFile.readAsBytes();

    final allCandidates = <_OcrCandidate>[];
    final tempFiles = <File>[];
    Future<void> collect(Future<_OcrCandidate?> Function() build) async {
      try {
        final candidate = await build();
        if (candidate == null) return;
        if (candidate.text.trim().isNotEmpty || allCandidates.isEmpty) {
          allCandidates.add(candidate);
        }
      } catch (_) {
        // Ignore individual variant failures and continue with the others.
      }
    }

    try {
      await collect(() => _recognizeFromFile(
            file: sourceFile,
            recognizer: _latinTextRecognizer,
            label: 'Original Scan',
          ));

      if (allCandidates.isEmpty) {
        return const _OcrCandidate(
          text: '',
          score: 0,
          label: 'No text recognized',
        );
      }

      var best = _pickBestCandidate(allCandidates);
      if (_isStrongOcrCandidate(best)) return best;

      await collect(() => _recognizeFromImageVariant(
            sourceBytes: sourceBytes,
            variant: _ocrVariantHandwritingSoft,
            recognizer: _latinTextRecognizer,
            label: 'Handwriting Soft Ink',
            tempFiles: tempFiles,
          ));

      best = _pickBestCandidate(allCandidates);
      if (_isStrongOcrCandidate(best)) return best;

      await collect(() => _recognizeFromImageVariant(
            sourceBytes: sourceBytes,
            variant: _ocrVariantHandwriting,
            recognizer: _latinTextRecognizer,
            label: 'Handwriting Boost',
            tempFiles: tempFiles,
          ));

      best = _pickBestCandidate(allCandidates);
      if (!_isStrongOcrCandidate(best) && _shouldTryExtraHandwriting(best)) {
        await collect(() => _recognizeFromImageVariant(
              sourceBytes: sourceBytes,
              variant: _ocrVariantHandwritingSharpen,
              recognizer: _latinTextRecognizer,
              label: 'Handwriting Sharpened Ink',
              tempFiles: tempFiles,
            ));
      }

      best = _pickBestCandidate(allCandidates);
      if (!_isStrongOcrCandidate(best) && _shouldTryExtraHandwriting(best)) {
        await collect(() => _recognizeFromImageVariant(
              sourceBytes: sourceBytes,
              variant: _ocrVariantHandwritingBinary,
              recognizer: _latinTextRecognizer,
              label: 'Handwriting Binary Ink',
              tempFiles: tempFiles,
            ));
      }

      best = _pickBestCandidate(allCandidates);
      if (!_isStrongOcrCandidate(best) && _shouldTryExtraHandwriting(best)) {
        await collect(() => _recognizeFromImageVariant(
              sourceBytes: sourceBytes,
              variant: _ocrVariantHandwritingCrop,
              recognizer: _latinTextRecognizer,
              label: 'Handwriting Margin Crop',
              tempFiles: tempFiles,
            ));
      }

      best = _pickBestCandidate(allCandidates);
      if (!_isStrongOcrCandidate(best) && _shouldTryBlueInkVariant(best)) {
        await collect(() => _recognizeFromImageVariant(
              sourceBytes: sourceBytes,
              variant: _ocrVariantBlueInk,
              recognizer: _latinTextRecognizer,
              label: 'Blue Ink Handwriting',
              tempFiles: tempFiles,
            ));
      }

      best = _pickBestCandidate(allCandidates);
      if (!_isStrongOcrCandidate(best)) {
        await collect(() => _recognizeFromImageVariant(
              sourceBytes: sourceBytes,
              variant: _ocrVariantUpscaled,
              recognizer: _latinTextRecognizer,
              label: 'Small Text Upscale',
              tempFiles: tempFiles,
            ));
      }

      best = _pickBestCandidate(allCandidates);
      if (!_isStrongOcrCandidate(best) && _shouldTryNewspaperVariant(best)) {
        await collect(() => _recognizeFromImageVariant(
              sourceBytes: sourceBytes,
              variant: _ocrVariantNewspaper,
              recognizer: _latinTextRecognizer,
              label: 'Newspaper Layout',
              tempFiles: tempFiles,
            ));
      }

      best = _pickBestCandidate(allCandidates);
      if (!_isStrongOcrCandidate(best) && _needsIndicFallback(best)) {
        await collect(() => _recognizeFromFile(
              file: sourceFile,
              recognizer: _indicTextRecognizer,
              label: 'Indic Script Original',
            ));
        await collect(() => _recognizeFromImageVariant(
              sourceBytes: sourceBytes,
              variant: _ocrVariantHandwritingSoft,
              recognizer: _indicTextRecognizer,
              label: 'Indic Script Handwriting Soft',
              tempFiles: tempFiles,
            ));
        await collect(() => _recognizeFromImageVariant(
              sourceBytes: sourceBytes,
              variant: _ocrVariantHandwriting,
              recognizer: _indicTextRecognizer,
              label: 'Indic Script Handwriting',
              tempFiles: tempFiles,
            ));
        if (allCandidates.isNotEmpty) {
          best = _pickBestCandidate(allCandidates);
        }
      }

      best = _pickBestCandidate(allCandidates);
      if (!_isStrongOcrCandidate(best) &&
          _shouldTryMalayalamTesseractFallback(best)) {
        await collect(() => _recognizeWithMalayalamTesseract(
              file: sourceFile,
              label: 'Malayalam Offline Fallback',
            ));
        if (allCandidates.isNotEmpty) {
          best = _pickBestCandidate(allCandidates);
        }
      }

      return best;
    } finally {
      for (final file in tempFiles) {
        try {
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {
          // Best effort cleanup; OCR result should not fail because temp delete failed.
        }
      }
    }
  }

  Future<_OcrCandidate?> _recognizeFromImageVariant({
    required Uint8List sourceBytes,
    required String variant,
    required TextRecognizer recognizer,
    required String label,
    required List<File> tempFiles,
  }) async {
    final processedBytes = await compute<Map<String, dynamic>, Uint8List?>(
      _buildOcrVariantBytes,
      <String, dynamic>{'bytes': sourceBytes, 'variant': variant},
    );
    if (processedBytes == null || processedBytes.isEmpty) {
      return null;
    }

    final tempDir = await getTemporaryDirectory();
    final file = File(
      '${tempDir.path}${Platform.pathSeparator}'
      'smart_ocr_${DateTime.now().microsecondsSinceEpoch}_${label.replaceAll(' ', '_')}.jpg',
    );
    await file.writeAsBytes(processedBytes, flush: true);
    tempFiles.add(file);

    return _recognizeFromFile(
      file: file,
      recognizer: recognizer,
      label: label,
    );
  }

  Future<_OcrCandidate> _recognizeFromFile({
    required File file,
    required TextRecognizer recognizer,
    required String label,
  }) async {
    final inputImage = InputImage.fromFile(file);
    final recognized = await recognizer.processImage(inputImage);
    final organizedText = _composeReadableText(recognized);
    final text =
        organizedText.isNotEmpty ? organizedText : recognized.text.trim();
    final score = _scoreOcrCandidate(recognized: recognized, text: text);
    return _OcrCandidate(text: text, score: score, label: label);
  }

  bool _isStrongOcrCandidate(_OcrCandidate candidate) {
    final tokenCount = _tokenCount(candidate.text);
    return candidate.score >= 78 && tokenCount >= 16;
  }

  bool _shouldTryNewspaperVariant(_OcrCandidate candidate) {
    final tokenCount = _tokenCount(candidate.text);
    return candidate.score < 60 || tokenCount < 18;
  }

  bool _shouldTryExtraHandwriting(_OcrCandidate candidate) {
    final tokenCount = _tokenCount(candidate.text);
    return candidate.score < 66 || tokenCount < 16;
  }

  bool _shouldTryBlueInkVariant(_OcrCandidate candidate) {
    final tokenCount = _tokenCount(candidate.text);
    return candidate.score < 64 || tokenCount < 14;
  }

  int _tokenCount(String text) {
    return text
        .split(RegExp(r'\s+'))
        .where((token) => token.trim().isNotEmpty)
        .length;
  }

  String _composeReadableText(RecognizedText recognized) {
    final blocks = recognized.blocks
        .where((block) => _blockToText(block).isNotEmpty)
        .toList();
    if (blocks.isEmpty) {
      return recognized.text.trim();
    }

    final orderedBlocks = _sortBlocksByReadingOrder(blocks);
    return orderedBlocks.map(_blockToText).join('\n\n').trim();
  }

  List<TextBlock> _sortBlocksByReadingOrder(List<TextBlock> blocks) {
    final defaultOrder = [...blocks]..sort(_compareBlockByTopThenLeft);
    if (blocks.length < 6) return defaultOrder;

    final minLeft =
        blocks.map((b) => b.boundingBox.left).reduce((a, b) => math.min(a, b));
    final maxRight =
        blocks.map((b) => b.boundingBox.right).reduce((a, b) => math.max(a, b));
    final pageWidth = maxRight - minLeft;
    if (pageWidth < 220) return defaultOrder;

    final byCenter = [...blocks]..sort(
        (a, b) => a.boundingBox.center.dx.compareTo(b.boundingBox.center.dx));
    final columns = <List<TextBlock>>[];
    double? previousCenter;
    for (final block in byCenter) {
      final center = block.boundingBox.center.dx;
      if (columns.isEmpty || previousCenter == null) {
        columns.add([block]);
      } else {
        final gap = center - previousCenter;
        if (gap > pageWidth * 0.22) {
          columns.add([block]);
        } else {
          columns.last.add(block);
        }
      }
      previousCenter = center;
    }

    final denseColumns = columns.where((column) => column.length >= 2).length;
    final hasNarrowBlocks = blocks
            .where((block) => block.boundingBox.width < pageWidth * 0.72)
            .length >=
        (blocks.length * 0.6).ceil();

    if (columns.length >= 2 && denseColumns >= 2 && hasNarrowBlocks) {
      final ordered = <TextBlock>[];
      for (final column in columns) {
        column.sort(_compareBlockByTopThenLeft);
        ordered.addAll(column);
      }
      return ordered;
    }

    return defaultOrder;
  }

  int _compareBlockByTopThenLeft(TextBlock a, TextBlock b) {
    final topDistance = (a.boundingBox.top - b.boundingBox.top).abs();
    if (topDistance <= 14) {
      return a.boundingBox.left.compareTo(b.boundingBox.left);
    }
    return a.boundingBox.top.compareTo(b.boundingBox.top);
  }

  String _blockToText(TextBlock block) {
    final lines = block.lines
        .map((line) => line.text.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      return block.text.trim();
    }
    return lines.join('\n');
  }

  _OcrCandidate _pickBestCandidate(List<_OcrCandidate> candidates) {
    var best = candidates.first;
    for (final candidate in candidates.skip(1)) {
      if (candidate.score > best.score) {
        best = candidate;
      }
    }
    return best;
  }

  bool _shouldTryMalayalamTesseractFallback(_OcrCandidate best) {
    if (!_enableMalayalamTesseractFallback) return false;
    final tokenCount = _tokenCount(best.text);
    final compactText = best.text.replaceAll(RegExp(r'\s+'), '');
    final charCount = compactText.length;
    final malayalamChars = _countMalayalamChars(best.text);
    final letterLikeChars = _countLetterLikeChars(compactText);
    final letterRatio = charCount == 0 ? 0.0 : letterLikeChars / charCount;
    if (malayalamChars >= 5 && best.score < 92) return true;
    return best.score < 56 || tokenCount < 9 || letterRatio < 0.34;
  }

  Future<bool> _isMalayalamTessdataAvailable() async {
    final cached = _isMalayalamTessdataReady;
    if (cached != null) return cached;
    try {
      final configRaw = await rootBundle.loadString(_tessdataConfigAssetPath);
      final decoded = jsonDecode(configRaw);
      if (decoded is! Map) {
        _isMalayalamTessdataReady = false;
        return false;
      }
      final files = decoded['files'];
      if (files is! List) {
        _isMalayalamTessdataReady = false;
        return false;
      }
      final hasMalayalamModel = files.any(
        (entry) =>
            entry.toString().trim().toLowerCase() == 'mal.traineddata',
      );
      if (!hasMalayalamModel) {
        _isMalayalamTessdataReady = false;
        return false;
      }
      await rootBundle.load(_malayalamTessDataAssetPath);
      _isMalayalamTessdataReady = true;
      return true;
    } catch (_) {
      _isMalayalamTessdataReady = false;
      return false;
    }
  }

  Future<_OcrCandidate?> _recognizeWithMalayalamTesseract({
    required File file,
    required String label,
  }) async {
    if (!Platform.isAndroid) return null;
    final hasTessdata = await _isMalayalamTessdataAvailable();
    if (!hasTessdata) return null;

    try {
      final text = await TesseractOcr.extractText(
        file.path,
        config: OCRConfig(
          language: 'mal',
          engine: OCREngine.tesseract,
          options: const {
            TesseractConfig.preserveInterwordSpaces: '1',
            TesseractConfig.pageSegMode: PageSegmentationMode.singleBlock,
          },
        ),
      ).timeout(const Duration(seconds: 8), onTimeout: () => '');
      final cleaned = text.trim();
      if (cleaned.isEmpty) return null;
      final score = _scoreRawTextCandidate(cleaned, confidenceHint: 0.64);
      return _OcrCandidate(text: cleaned, score: score, label: label);
    } catch (_) {
      return null;
    }
  }

  bool _containsLetters(String value) {
    return _ocrLetterPattern.hasMatch(value);
  }

  bool _containsDigits(String value) {
    return _digitPattern.hasMatch(value);
  }

  int _countLetterLikeChars(String value) {
    return _ocrLetterPattern.allMatches(value).length;
  }

  int _countMalayalamChars(String value) {
    return _malayalamPattern.allMatches(value).length;
  }

  bool _containsMalayalamText(String value) {
    return _malayalamPattern.hasMatch(value);
  }

  bool _isMixedGarbageToken(String token) {
    return _containsLetters(token) && _containsDigits(token);
  }

  bool _isLetterLikeToken(String token) {
    final letterLikeChars = _countLetterLikeChars(token);
    return letterLikeChars >= 3 && !_containsDigits(token);
  }

  Set<String> _recognizedLanguageCodes(RecognizedText recognized) {
    final languages = <String>{};
    for (final block in recognized.blocks) {
      for (final language in block.recognizedLanguages) {
        final normalized = language.trim().toLowerCase();
        if (normalized.isNotEmpty) {
          languages.add(normalized);
        }
      }
      for (final line in block.lines) {
        for (final language in line.recognizedLanguages) {
          final normalized = language.trim().toLowerCase();
          if (normalized.isNotEmpty) {
            languages.add(normalized);
          }
        }
      }
    }
    return languages;
  }

  bool _needsIndicFallback(_OcrCandidate best) {
    final tokens = best.text
        .split(RegExp(r'\s+'))
        .where((token) => token.trim().isNotEmpty)
        .toList();
    final compactText = best.text.replaceAll(RegExp(r'\s+'), '');
    final charCount = compactText.length;
    final letterLikeChars = _countLetterLikeChars(compactText);
    final letterRatio = charCount == 0 ? 0.0 : letterLikeChars / charCount;
    final hasMalayalam = _containsMalayalamText(best.text);
    return best.score < 24 ||
        tokens.length < 5 ||
        (!hasMalayalam && letterRatio < 0.28 && best.score < 56);
  }

  double _scoreRawTextCandidate(
    String text, {
    required double confidenceHint,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 0;

    final tokens = trimmed
        .split(RegExp(r'\s+'))
        .where((token) => token.trim().isNotEmpty)
        .toList();
    final longTokenCount =
        tokens.where((token) => token.runes.length >= 2).length;
    final singleTokenCount =
        tokens.where((token) => token.runes.length == 1).length;
    final charCount = trimmed.replaceAll(RegExp(r'\s+'), '').length;
    final pseudoLineCount = tokens.length <= 4 ? tokens.length : tokens.length ~/ 2;
    final letterLikeCharCount = _countLetterLikeChars(trimmed);
    final malayalamCharCount = _countMalayalamChars(trimmed);
    final oddSymbolCount =
        RegExp(r'[@#$%^*_+=\\|/<>{}~`]').allMatches(trimmed).length;
    final mixedGarbageWords = tokens
        .where((token) => _isMixedGarbageToken(token))
        .length;
    final letterLikeWords = tokens
        .where((token) => _isLetterLikeToken(token))
        .length;

    var score = (longTokenCount * 2.4) +
        (math.min(charCount, 500) / 8.0) +
        (pseudoLineCount * 0.8) +
        (confidenceHint * 18.0);

    final scriptLetterRatio =
        charCount == 0 ? 0.0 : letterLikeCharCount / charCount;
    if (scriptLetterRatio < 0.45) {
      score -= 12.0;
    } else if (scriptLetterRatio > 0.70) {
      score += 4.0;
    }

    score += letterLikeWords * 1.1;
    score -= mixedGarbageWords * 1.6;
    score -= oddSymbolCount * 1.6;
    if (malayalamCharCount >= 4) {
      score += math.min(14.0, malayalamCharCount / 4.2);
    }

    final singleTokenRatio =
        tokens.isEmpty ? 1.0 : singleTokenCount / tokens.length;
    if (singleTokenRatio > 0.45) {
      score -= 9.0;
    }
    if (tokens.length >= 10 &&
        letterLikeWords < (tokens.length * 0.32).floor()) {
      score -= 7.0;
    }

    final repeatNoise = RegExp(r'(.)\1{4,}').allMatches(trimmed).length;
    final symbolNoise = RegExp(r'[{}<>~`|]').allMatches(trimmed).length;
    score -= repeatNoise * 3.0;
    score -= symbolNoise * 1.1;

    return score;
  }

  double _scoreOcrCandidate({
    required RecognizedText recognized,
    required String text,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 0;

    final tokens = trimmed
        .split(RegExp(r'\s+'))
        .where((token) => token.trim().isNotEmpty)
        .toList();
    final longTokenCount =
        tokens.where((token) => token.runes.length >= 2).length;
    final singleTokenCount =
        tokens.where((token) => token.runes.length == 1).length;
    final charCount = trimmed.replaceAll(RegExp(r'\s+'), '').length;
    final lineCount = recognized.blocks.fold<int>(
      0,
      (sum, block) => sum + block.lines.length,
    );
    final confidence = _averageLineConfidence(recognized);
    final letterLikeCharCount = _countLetterLikeChars(trimmed);
    final malayalamCharCount = _countMalayalamChars(trimmed);
    final recognizedLanguages = _recognizedLanguageCodes(recognized);
    final hasMalayalamLanguageHint = recognizedLanguages.any(
      (language) => language == 'ml' || language.startsWith('ml-'),
    );
    final oddSymbolCount =
        RegExp(r'[@#$%^*_+=\\|/<>{}~`]').allMatches(trimmed).length;
    final mixedGarbageWords = tokens
        .where((token) => _isMixedGarbageToken(token))
        .length;
    final letterLikeWords = tokens
        .where((token) => _isLetterLikeToken(token))
        .length;

    var score = (longTokenCount * 2.4) +
        (math.min(charCount, 500) / 8.0) +
        (lineCount * 0.8) +
        (confidence * 18.0);

    final scriptLetterRatio =
        charCount == 0 ? 0.0 : letterLikeCharCount / charCount;
    if (scriptLetterRatio < 0.45) {
      score -= 12.0;
    } else if (scriptLetterRatio > 0.70) {
      score += 4.0;
    }

    score += letterLikeWords * 1.1;
    score -= mixedGarbageWords * 1.6;
    score -= oddSymbolCount * 1.6;
    if (malayalamCharCount >= 4) {
      score += math.min(12.0, malayalamCharCount / 5.0);
    }
    if (hasMalayalamLanguageHint) {
      score += 5.0;
    }

    final singleTokenRatio =
        tokens.isEmpty ? 1.0 : singleTokenCount / tokens.length;
    if (singleTokenRatio > 0.45) {
      score -= 9.0;
    }
    if (tokens.length >= 10 &&
        letterLikeWords < (tokens.length * 0.32).floor()) {
      score -= 7.0;
    }

    final repeatNoise = RegExp(r'(.)\1{4,}').allMatches(trimmed).length;
    final symbolNoise = RegExp(r'[{}<>~`|]').allMatches(trimmed).length;
    score -= repeatNoise * 3.0;
    score -= symbolNoise * 1.1;

    return score;
  }

  double _averageLineConfidence(RecognizedText recognized) {
    final confidenceValues = <double>[];
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        if (line.confidence != null) {
          confidenceValues.add(line.confidence!.clamp(0.0, 1.0));
        }
      }
    }
    if (confidenceValues.isEmpty) return 0.55;
    final total = confidenceValues.reduce((a, b) => a + b);
    return total / confidenceValues.length;
  }

  Future<bool> _trySetTtsLanguage(String languageCode) async {
    try {
      final result = await flutterTts.setLanguage(languageCode);
      if (result is bool) return result;
      if (result is num) return result == 1;
      if (result is String) {
        final normalized = result.trim().toLowerCase();
        return normalized == '1' || normalized == 'success';
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _setSpeechLanguageForText(String text) async {
    final hasMalayalam = _containsMalayalamText(text);
    final preferred = hasMalayalam ? 'ml-IN' : 'en-IN';
    final fallback = hasMalayalam ? 'en-IN' : 'ml-IN';
    final appliedPreferred = await _trySetTtsLanguage(preferred);
    if (!appliedPreferred) {
      await _trySetTtsLanguage(fallback);
    }
  }

  Future<void> _startSpeaking() async {
    if (_extractedText.isEmpty) return;
    setState(() {
      _isSpeaking = true;
      _isPaused = false;
    });
    try {
      await flutterTts.stop();
      await _setSpeechLanguageForText(_extractedText);
      await flutterTts.setPitch(1.0);
      await flutterTts.setSpeechRate(_speechRate);
      await flutterTts.speak(_extractedText);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSpeaking = false;
        _isPaused = false;
      });
    }
  }

  Future<void> _pauseSpeaking() async {
    if (!_isSpeaking || _isPaused) return;
    setState(() {
      _isSpeaking = true;
      _isPaused = true;
    });
    await flutterTts.pause();
  }

  Future<void> _resumeSpeaking() async {
    if (!_isPaused || _extractedText.isEmpty) return;
    setState(() {
      _isSpeaking = true;
      _isPaused = false;
    });
    await _setSpeechLanguageForText(_extractedText);
    await flutterTts.setSpeechRate(_speechRate);
    await flutterTts.speak(_extractedText);
  }

  Future<void> _stopSpeaking() async {
    await flutterTts.stop();
    if (!mounted) return;
    setState(() {
      _isSpeaking = false;
      _isPaused = false;
    });
  }

  @override
  void dispose() {
    _latinTextRecognizer.close();
    _indicTextRecognizer.close();
    flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Auralight Assistant'),
        centerTitle: true,
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
              title: const Text('Medicine Reader',
                  style: TextStyle(fontWeight: FontWeight.w500)),
              onTap: () {
                Navigator.pop(context); // Close the drawer
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const MedicineReaderScreen()));
              },
              tileColor: Colors.purple[50],
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            const SizedBox(height: 12), // Spacing between buttons
            SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.settings, color: Colors.grey[700]),
              title: Text('Settings',
                  style: TextStyle(fontWeight: FontWeight.w500)),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
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
                if (!context.mounted) return;

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
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final extractedPanelHeight =
                constraints.maxHeight < 720 ? 240.0 : 300.0;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(minHeight: constraints.maxHeight - 32),
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
                    // Extracted Text Area
                    SizedBox(
                      height: extractedPanelHeight,
                      child: Semantics(
                        liveRegion: true,
                        label: 'Extracted bill text area',
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
                                  Icon(Icons.text_fields,
                                      color: Colors.green[700]),
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
                                      icon: Icon(
                                        _isPaused
                                            ? Icons.play_arrow
                                            : Icons.volume_up,
                                        color: Colors.blue,
                                      ),
                                      onPressed: _isPaused
                                          ? _resumeSpeaking
                                          : _startSpeaking,
                                      tooltip: _isPaused
                                          ? 'Resume reading'
                                          : 'Read aloud',
                                    ),
                                ],
                              ),
                              SizedBox(height: 12),
                              Expanded(
                                child: _isLoading
                                    ? Center(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            CircularProgressIndicator(
                                              color: Colors.green,
                                            ),
                                            SizedBox(height: 16),
                                            Text(
                                              'Extracting text...',
                                              style: TextStyle(
                                                  color: Colors.grey[600]),
                                              textAlign: TextAlign.center,
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
                    ),
                    const SizedBox(height: 12),
                    _buildVoiceStatusCard(),
                    const SizedBox(height: 12),
                    _buildSpeechRateCard(),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        Semantics(
                          button: true,
                          label: 'Start reading extracted text',
                          child: ElevatedButton.icon(
                            onPressed:
                                _extractedText.isEmpty ? null : _startSpeaking,
                            icon: const Icon(Icons.play_circle_fill),
                            label: const Text('Start'),
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: 'Pause voice reading',
                          child: ElevatedButton.icon(
                            onPressed: (_isSpeaking && !_isPaused)
                                ? _pauseSpeaking
                                : null,
                            icon: const Icon(Icons.pause_circle_filled),
                            label: const Text('Pause'),
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: 'Resume voice reading',
                          child: ElevatedButton.icon(
                            onPressed: _isPaused ? _resumeSpeaking : null,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Resume'),
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: 'Stop voice reading',
                          child: ElevatedButton.icon(
                            onPressed: (_isSpeaking || _isPaused)
                                ? _stopSpeaking
                                : null,
                            icon: const Icon(Icons.stop_circle),
                            label: const Text('Stop'),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 20),

                    // Quick Action Buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Expanded(
                          child: Semantics(
                            button: true,
                            label: 'Take bill photo with camera',
                            child: ElevatedButton.icon(
                              icon: Icon(Icons.camera_alt, size: 20),
                              label: Text("Camera"),
                              onPressed: () => _pickImage(ImageSource.camera),
                              style: ElevatedButton.styleFrom(
                                padding: EdgeInsets.symmetric(vertical: 14),
                                backgroundColor: Colors.green[700],
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Semantics(
                            button: true,
                            label: 'Choose bill image from gallery',
                            child: ElevatedButton.icon(
                              icon: Icon(Icons.photo_library, size: 20),
                              label: Text("Gallery"),
                              onPressed: () => _pickImage(ImageSource.gallery),
                              style: ElevatedButton.styleFrom(
                                padding: EdgeInsets.symmetric(vertical: 14),
                                backgroundColor: Colors.blue[700],
                                foregroundColor: Colors.white,
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
                      child: Semantics(
                        button: true,
                        label: 'Open real time obstacle navigation',
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
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // --- MEDICINE MODULE DASHBOARD BUTTON ---
                    Semantics(
                      button: true,
                      label: 'Open medicine prescription reader module',
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.health_and_safety, size: 22),
                          label: const Text('MEDICINE PRESCRIPTION READER'),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const MedicineReaderScreen()),
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            backgroundColor: const Color(0xFF3B0A63),
                            foregroundColor: Colors.white,
                            elevation: 5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (_extractedText.isNotEmpty) {
            if (_isPaused) {
              _resumeSpeaking();
            } else if (_isSpeaking) {
              _pauseSpeaking();
            } else {
              _startSpeaking();
            }
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
        tooltip: _isPaused
            ? 'Resume reading'
            : _isSpeaking
                ? 'Pause reading'
                : 'Read extracted text',
        child: Icon(
          _isPaused
              ? Icons.play_arrow
              : _isSpeaking
                  ? Icons.pause
                  : Icons.volume_up,
        ),
      ),
    );
  }
}
