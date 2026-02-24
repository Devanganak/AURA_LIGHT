import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:auralight/settings_screen.dart';

class MedicineReaderScreen extends StatefulWidget {
  final String? initialReminderPayload;

  const MedicineReaderScreen({
    super.key,
    this.initialReminderPayload,
  });

  @override
  _MedicineReaderScreenState createState() => _MedicineReaderScreenState();
}

class _MedicineReaderScreenState extends State<MedicineReaderScreen>
    with WidgetsBindingObserver {
  static const String _prescriptionStorageKey = 'stored_prescription_items_v1';
  static const String _prescriptionRawTextStorageKey =
      'stored_prescription_raw_text_v1';
  static const String _reminderStorageKey = 'stored_manual_reminders_v1';
  static const String _androidAlarmChannelId = 'med_alarm_channel_v2';
  static const String _notificationActionSnooze = 'snooze_5_min';
  static const String _notificationActionDismiss = 'dismiss_alarm';
  static const int _dueWindowMinutes = 45;
  static const int _upcomingSuggestionCount = 3;
  static const int _smartMatchThreshold = 20;
  static const int _smartStrongMatchThreshold = 45;
  static const Color _mrdScanButtonColor = Color(0xFF0B3A8A);
  static const Color _mrdVerifyButtonColor = Color(0xFF0A5B39);
  static const Color _mrdManualButtonColor = Color(0xFF7A2F00);
  static const Color _mrdActionTextColor = Colors.white;
  static const Set<String> _ocrStopWords = <String>{
    'rx',
    'sig',
    'po',
    'od',
    'bd',
    'bid',
    'tds',
    'tid',
    'qid',
    'hs',
    'sos',
    'stat',
    'for',
    'days',
    'day',
    'week',
    'weeks',
    'month',
    'months',
    'tab',
    'tablet',
    'tablets',
    'syp',
    'syrup',
    'inj',
    'injection',
    'capsule',
    'capsules',
    'cap',
    'strip',
    'dose',
    'dosage',
    'take',
    'morning',
    'night',
    'evening',
    'afternoon',
    'noon',
    'before',
    'after',
    'food',
    'medicine',
    'medicines',
    'with',
    'without',
    'and',
    'or',
    'at',
    'am',
    'pm',
    'mg',
    'ml',
    'mcg',
    'units',
    'ip',
    'usp',
  };

  File? _image;
  final List<Map<String, dynamic>> _myReminders = [];
  final List<Map<String, dynamic>> _prescriptionEntries = [];
  String _resultText = 'Scan a prescription or strip.';
  String _lastExtractedPrescriptionText = '';

  final TextRecognizer _textRecognizer =
      TextRecognizer(script: TextRecognitionScript.latin);
  final FlutterTts _flutterTts = FlutterTts();
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  late final Future<void> _notificationsReady;
  AndroidScheduleMode _androidScheduleMode =
      AndroidScheduleMode.inexactAllowWhileIdle;
  Timer? _foregroundReminderTimer;
  final List<Map<String, String>> _pendingReminderDialogs = [];
  final Map<int, String> _lastShownSlotByReminderId = {};
  bool _reminderDialogVisible = false;
  bool _isAppResumed = true;
  bool _showReliabilityCheck = false;
  bool _isReliabilityStatusLoading = false;
  bool? _notificationsEnabled;
  bool? _exactAlarmEnabled;
  bool? _fullScreenIntentEnabled;
  bool? _dndBypassEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _notificationsReady = _initNotifications();
    _loadStoredPrescription();
    _restoreStoredReminders();
    _startForegroundReminderWatcher();
    _consumeInitialReminderPayload();
    Future<void>.microtask(() async {
      await _notificationsReady;
      if (!mounted) return;
      if (_showReliabilityCheck) {
        await _refreshAlarmReliabilityStatus();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _foregroundReminderTimer?.cancel();
    _textRecognizer.close();
    _flutterTts.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppResumed = state == AppLifecycleState.resumed;
    if (_isAppResumed) {
      _showNextReminderPopup();
      if (_showReliabilityCheck) {
        _refreshAlarmReliabilityStatus();
      }
    }
  }

  Future<void> _initNotifications() async {
    tz.initializeTimeZones();

    final androidNotifications =
        _notificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidNotifications?.requestNotificationsPermission();
    final hasExactBefore =
        await androidNotifications?.canScheduleExactNotifications() ?? false;
    if (!hasExactBefore) {
      await androidNotifications?.requestExactAlarmsPermission();
    }
    final hasExactAfter =
        await androidNotifications?.canScheduleExactNotifications() ?? false;
    _androidScheduleMode = hasExactAfter
        ? AndroidScheduleMode.alarmClock
        : AndroidScheduleMode.inexactAllowWhileIdle;

    // Notification callback routing is initialized globally in main.dart
    // so it can work even when this screen is not currently active.
  }

  void _consumeInitialReminderPayload() {
    final payload = widget.initialReminderPayload;
    if (payload == null || payload.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is! Map) return;
        final reminder = Map<String, dynamic>.from(decoded);
        final medName = (reminder['name'] as String? ?? '').trim();
        final dosage = (reminder['dosage'] as String? ?? '').trim();
        _enqueueReminderPopup(
          medName.isEmpty ? 'Medicine' : medName,
          dosage,
        );
      } catch (_) {
        // Ignore malformed payloads and keep app stable.
      }
    });
  }

  String _statusText(bool? value, {String unknownText = 'Not Checked'}) {
    if (value == null) return unknownText;
    return value ? 'Granted' : 'Missing';
  }

  Color _statusColor(bool? value) {
    if (value == null) return Colors.orange;
    return value ? Colors.green : Colors.red;
  }

  Future<void> _refreshAlarmReliabilityStatus() async {
    final androidNotifications =
        _notificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidNotifications == null) return;

    if (mounted) {
      setState(() => _isReliabilityStatusLoading = true);
    }

    final notificationsEnabled =
        await androidNotifications.areNotificationsEnabled();
    final exactAlarmEnabled =
        await androidNotifications.canScheduleExactNotifications();
    final dndBypassEnabled =
        await androidNotifications.hasNotificationPolicyAccess();

    if (!mounted) return;
    setState(() {
      _notificationsEnabled = notificationsEnabled;
      _exactAlarmEnabled = exactAlarmEnabled;
      _dndBypassEnabled = dndBypassEnabled;
      _isReliabilityStatusLoading = false;
    });
  }

  Future<void> _requestNotificationsPermission() async {
    final androidNotifications =
        _notificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidNotifications?.requestNotificationsPermission();
    await _refreshAlarmReliabilityStatus();
  }

  Future<void> _requestExactAlarmPermission() async {
    final androidNotifications =
        _notificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidNotifications?.requestExactAlarmsPermission();
    await _refreshAlarmReliabilityStatus();
  }

  Future<void> _requestFullScreenIntentPermission() async {
    final androidNotifications =
        _notificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    final granted =
        await androidNotifications?.requestFullScreenIntentPermission();
    if (!mounted) return;
    setState(() {
      _fullScreenIntentEnabled = granted;
    });
  }

  Future<void> _requestDndBypassPermission() async {
    final androidNotifications =
        _notificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidNotifications?.requestNotificationPolicyAccess();
    await _refreshAlarmReliabilityStatus();
  }

  Widget _buildReliabilityRow({
    required String label,
    required bool? status,
    required VoidCallback onPressed,
    String unknownText = 'Not Checked',
    String buttonText = 'Grant',
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$label: ${_statusText(status, unknownText: unknownText)}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _statusColor(status),
              ),
            ),
          ),
          OutlinedButton(
            onPressed: onPressed,
            child: Text(buttonText),
          ),
        ],
      ),
    );
  }

  void _startForegroundReminderWatcher() {
    _foregroundReminderTimer?.cancel();
    _foregroundReminderTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _checkForegroundReminders(),
    );
    _checkForegroundReminders();
  }

  String _reminderMessage(String medName, String dosage) {
    if (dosage.trim().isEmpty) {
      return 'Time to take $medName now.';
    }
    return 'Time to take $medName ($dosage) now.';
  }

  void _enqueueReminderPopup(String medName, String dosage) {
    _pendingReminderDialogs.add(<String, String>{
      'name': medName,
      'dosage': dosage,
    });
    _showNextReminderPopup();
  }

  void _showNextReminderPopup() {
    if (!mounted || !_isAppResumed) return;
    if (_reminderDialogVisible || _pendingReminderDialogs.isEmpty) return;

    final next = _pendingReminderDialogs.removeAt(0);
    final medName = next['name'] ?? 'Medicine';
    final dosage = next['dosage'] ?? '';
    final message = _reminderMessage(medName, dosage);

    _reminderDialogVisible = true;
    _flutterTts.speak(message);
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Medicine Alarm',
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, _, __) {
        return SafeArea(
          child: Scaffold(
            backgroundColor: Colors.red.shade700,
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.alarm,
                    size: 90,
                    color: Colors.white,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Medicine Reminder',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 36),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        await _scheduleSnoozeNotification(
                          medName: medName,
                          dosage: dosage,
                          parentReminderId: null,
                        );
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.red.shade700,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: const Text('Snooze 5 min'),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white, width: 2),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: const Text('Dismiss'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ).then((_) {
      _reminderDialogVisible = false;
      _showNextReminderPopup();
    });
  }

  bool _isExactMinuteNow(DateTime now, int hour, int minute) {
    return now.hour == hour && now.minute == minute;
  }

  String _slotKey(DateTime now, int hour, int minute) {
    return '${now.year}-${now.month}-${now.day}-$hour-$minute';
  }

  bool _markSlotTriggered(int reminderId, DateTime now, int hour, int minute) {
    final key = _slotKey(now, hour, minute);
    if (_lastShownSlotByReminderId[reminderId] == key) return false;
    _lastShownSlotByReminderId[reminderId] = key;
    return true;
  }

  void _checkForegroundReminders() {
    if (!mounted || !_isAppResumed) return;
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    var shouldPersistManualReminders = false;

    for (final item in _prescriptionEntries) {
      final reminderId = item['id'] as int?;
      final hour = item['hour'] as int?;
      final minute = item['minute'] as int?;
      if (reminderId == null || hour == null || minute == null) continue;

      if (!_isExactMinuteNow(now, hour, minute)) continue;
      if (!_markSlotTriggered(reminderId, now, hour, minute)) continue;

      final medName = (item['name'] as String? ?? 'Medicine').trim();
      final dosage = (item['dosage'] as String? ?? '').trim();
      _enqueueReminderPopup(medName, dosage);
    }

    for (final item in _myReminders) {
      final reminderId = item['id'] as int?;
      if (reminderId == null) continue;

      final intervalHours = item['intervalHours'] as int?;
      if (intervalHours != null && intervalHours > 0) {
        final intervalMs = Duration(hours: intervalHours).inMilliseconds;
        final oldNextTriggerMs = item['nextTriggerEpochMs'] as int?;
        var nextTriggerMs = oldNextTriggerMs ??
            now.add(Duration(hours: intervalHours)).millisecondsSinceEpoch;
        if (nextTriggerMs <= nowMs) {
          if (_markSlotTriggered(reminderId, now, now.hour, now.minute)) {
            final medName = (item['name'] as String? ?? 'Medicine').trim();
            final dosage = (item['dosage'] as String? ?? '').trim();
            _enqueueReminderPopup(medName, dosage);
          }
          while (nextTriggerMs <= nowMs) {
            nextTriggerMs += intervalMs;
          }
        }
        item['nextTriggerEpochMs'] = nextTriggerMs;
        if (oldNextTriggerMs != nextTriggerMs) {
          shouldPersistManualReminders = true;
        }
        continue;
      }

      final hour = item['hour'] as int?;
      final minute = item['minute'] as int?;
      if (hour == null || minute == null) continue;

      final oldNextTriggerMs = item['nextTriggerEpochMs'] as int?;
      var nextTriggerMs = oldNextTriggerMs ??
          DateTime(now.year, now.month, now.day, hour, minute)
              .millisecondsSinceEpoch;
      if (nextTriggerMs <= nowMs) {
        if (_markSlotTriggered(reminderId, now, now.hour, now.minute)) {
          final medName = (item['name'] as String? ?? 'Medicine').trim();
          final dosage = (item['dosage'] as String? ?? '').trim();
          _enqueueReminderPopup(medName, dosage);
        }
        while (nextTriggerMs <= nowMs) {
          nextTriggerMs += const Duration(days: 1).inMilliseconds;
        }
      }
      item['nextTriggerEpochMs'] = nextTriggerMs;
      if (oldNextTriggerMs != nextTriggerMs) {
        shouldPersistManualReminders = true;
      }

      if (_isExactMinuteNow(now, hour, minute) &&
          _markSlotTriggered(reminderId, now, hour, minute)) {
        final medName = (item['name'] as String? ?? 'Medicine').trim();
        final dosage = (item['dosage'] as String? ?? '').trim();
        _enqueueReminderPopup(medName, dosage);
      }
    }

    if (shouldPersistManualReminders) {
      _persistManualReminders();
    }
  }

  Future<void> _loadStoredPrescription() async {
    final prefs = await SharedPreferences.getInstance();
    final rawExtractedText =
        prefs.getString(_prescriptionRawTextStorageKey) ?? '';
    final raw = prefs.getString(_prescriptionStorageKey);
    if (raw == null || raw.isEmpty) {
      if (rawExtractedText.isEmpty || !mounted) return;
      setState(() {
        _lastExtractedPrescriptionText = rawExtractedText;
      });
      return;
    }

    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      if (rawExtractedText.isEmpty || !mounted) return;
      setState(() {
        _lastExtractedPrescriptionText = rawExtractedText;
      });
      return;
    }
    final normalized = decoded
        .whereType<Map>()
        .map(_normalizePrescriptionEntry)
        .whereType<Map<String, dynamic>>()
        .toList();
    if (normalized.isEmpty) {
      if (rawExtractedText.isEmpty || !mounted) return;
      setState(() {
        _lastExtractedPrescriptionText = rawExtractedText;
      });
      return;
    }

    setState(() {
      _prescriptionEntries
        ..clear()
        ..addAll(normalized);
      _lastExtractedPrescriptionText = rawExtractedText;
    });
  }

  Future<void> _persistPrescription(
      [List<Map<String, dynamic>>? entries]) async {
    final prefs = await SharedPreferences.getInstance();
    final dataToStore = entries ?? _prescriptionEntries;
    await prefs.setString(
      _prescriptionStorageKey,
      jsonEncode(dataToStore),
    );
  }

  Future<void> _persistExtractedPrescriptionText(String text) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prescriptionRawTextStorageKey, text.trim());
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  Map<String, dynamic>? _normalizePrescriptionEntry(Map<dynamic, dynamic> raw) {
    final name = (raw['name'] as String? ?? '').trim();
    if (name.isEmpty) return null;

    final hour = _asInt(raw['hour']);
    final minute = _asInt(raw['minute']);

    final id = _asInt(raw['id']) ??
        (DateTime.now().millisecondsSinceEpoch + (hour ?? 0) + (minute ?? 0))
            .remainder(2147483647);
    final dosage = (raw['dosage'] as String? ?? '').trim();
    final quantity = _asInt(raw['quantity']);
    final durationDays = _asInt(raw['durationDays']);
    final durationText = (raw['durationText'] as String? ?? '').trim();
    final confidenceScore = _asInt(raw['confidenceScore']);
    final confidenceLabel = (raw['confidenceLabel'] as String? ?? '').trim();
    final rawTimeLabel = (raw['timeLabel'] as String? ?? '').trim();

    return <String, dynamic>{
      'id': id,
      'name': name,
      'dosage': dosage,
      'quantity': quantity,
      'durationDays': durationDays,
      'durationText': durationText,
      'confidenceScore': confidenceScore,
      'confidenceLabel': confidenceLabel,
      'hour': hour,
      'minute': minute,
      'timeLabel': rawTimeLabel.isNotEmpty
          ? rawTimeLabel
          : (hour != null && minute != null
              ? _formatTimeLabelFrom24h(hour, minute)
              : 'Not set'),
    };
  }

  Future<void> _persistManualReminders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _reminderStorageKey,
      jsonEncode(_myReminders),
    );
  }

  Future<void> _restoreStoredReminders() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_reminderStorageKey);
    if (raw == null || raw.isEmpty) return;

    final decoded = jsonDecode(raw);
    if (decoded is! List) return;

    final restored = <Map<String, dynamic>>[];
    final now = DateTime.now();

    for (final entry in decoded.whereType<Map>()) {
      final item = Map<String, dynamic>.from(entry);
      final id = _asInt(item['id']);
      if (id == null) continue;

      final name = (item['name'] as String? ?? '').trim();
      if (name.isEmpty) continue;

      final dosage = (item['dosage'] as String? ?? '').trim();
      var intervalHours = _asInt(item['intervalHours']);
      intervalHours ??= _asInt(item['interval']);
      final hour = _asInt(item['hour']);
      final minute = _asInt(item['minute']);

      if ((intervalHours == null || intervalHours <= 0) &&
          (hour == null || minute == null)) {
        continue;
      }

      final normalized = <String, dynamic>{
        'id': id,
        'name': name,
        'dosage': dosage,
        'intervalHours': intervalHours,
        'hour': hour,
        'minute': minute,
        'interval': intervalHours?.toString() ?? '',
        'time': item['time'] as String? ??
            (hour != null && minute != null
                ? 'at ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}'
                : 'every $intervalHours hours'),
      };

      final storedNextTriggerMs = _asInt(item['nextTriggerEpochMs']);
      if (storedNextTriggerMs != null) {
        normalized['nextTriggerEpochMs'] = storedNextTriggerMs;
      } else if (intervalHours != null && intervalHours > 0) {
        normalized['nextTriggerEpochMs'] =
            now.add(Duration(hours: intervalHours)).millisecondsSinceEpoch;
      } else if (hour != null && minute != null) {
        var nextTrigger = DateTime(now.year, now.month, now.day, hour, minute);
        if (!nextTrigger.isAfter(now)) {
          nextTrigger = nextTrigger.add(const Duration(days: 1));
        }
        normalized['nextTriggerEpochMs'] = nextTrigger.millisecondsSinceEpoch;
      }

      restored.add(normalized);
    }

    if (restored.isEmpty) return;

    if (mounted) {
      setState(() {
        _myReminders
          ..clear()
          ..addAll(restored);
      });
    } else {
      _myReminders
        ..clear()
        ..addAll(restored);
    }

    await _notificationsReady;
    for (final item in restored) {
      final notificationId = item['id'] as int;
      final medName = item['name'] as String;
      final dosage = item['dosage'] as String? ?? '';
      final intervalHours = item['intervalHours'] as int?;
      final hour = item['hour'] as int?;
      final minute = item['minute'] as int?;
      final specificTime = (hour != null && minute != null)
          ? TimeOfDay(hour: hour, minute: minute)
          : null;

      await _notificationsPlugin.cancel(notificationId);
      await _scheduleSystemNotification(
        notificationId,
        medName,
        dosage,
        intervalHours,
        specificTime,
      );
    }

    await _persistManualReminders();
  }

  void _showManualEntryDialog({int? index}) async {
    final isEditing = index != null;

    final medController = TextEditingController(
      text: isEditing ? _myReminders[index]['name'] : '',
    );
    final dosageController = TextEditingController(
      text: isEditing ? _myReminders[index]['dosage'] : '',
    );
    final intervalController = TextEditingController(
      text: isEditing ? _myReminders[index]['interval'] : '',
    );

    TimeOfDay? selectedTime;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isEditing ? 'Modify Medication' : 'Set Medication Alert'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: medController,
                decoration: const InputDecoration(labelText: 'Medicine Name'),
              ),
              TextField(
                controller: dosageController,
                decoration:
                    const InputDecoration(labelText: 'Dosage (e.g. 500mg)'),
              ),
              TextField(
                controller: intervalController,
                decoration:
                    const InputDecoration(labelText: 'Interval (Hours)'),
                keyboardType: TextInputType.number,
              ),
              const Divider(),
              const Text('OR Set Specific Time:'),
              ElevatedButton(
                onPressed: () async {
                  selectedTime = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.now(),
                  );
                },
                child: const Text('Pick Start Time'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              await _saveAndSchedule(
                medController.text,
                dosageController.text,
                intervalController.text,
                selectedTime,
                index: index,
              );
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(isEditing ? 'Update' : 'Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAndSchedule(
    String name,
    String dosage,
    String interval,
    TimeOfDay? specificTime, {
    int? index,
  }) async {
    if (name.trim().isEmpty) return;
    final parsedInterval = int.tryParse(interval);
    if (specificTime == null &&
        (parsedInterval == null || parsedInterval <= 0)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Set a valid interval (hours) or pick a specific time.'),
          ),
        );
      }
      return;
    }

    await _notificationsReady;
    if (!mounted) return;
    final effectiveInterval = specificTime == null ? parsedInterval : null;

    final reminderId = index != null
        ? _myReminders[index]['id'] as int
        : DateTime.now().millisecondsSinceEpoch % 100000;

    final displayTime = specificTime != null
        ? 'at ${specificTime.format(context)}'
        : 'every $effectiveInterval hours';
    final now = DateTime.now();
    final nextTrigger = specificTime != null
        ? _nextDailyTrigger(now, specificTime)
        : now.add(Duration(hours: effectiveInterval!));

    final newReminder = <String, dynamic>{
      'name': name.trim(),
      'dosage': dosage.trim(),
      'interval': effectiveInterval?.toString() ?? '',
      'time': displayTime,
      'id': reminderId,
      'intervalHours': effectiveInterval,
      'hour': specificTime?.hour,
      'minute': specificTime?.minute,
      'nextTriggerEpochMs': nextTrigger.millisecondsSinceEpoch,
    };

    if (index != null) {
      await _notificationsPlugin.cancel(reminderId);
    }

    setState(() {
      if (index != null) {
        _myReminders[index] = newReminder;
      } else {
        _myReminders.add(newReminder);
      }
    });

    await _flutterTts
        .speak('Reminder saved for ${name.trim()}, ${dosage.trim()}');
    await _scheduleSystemNotification(
      reminderId,
      name.trim(),
      dosage.trim(),
      effectiveInterval,
      specificTime,
    );
    await _persistManualReminders();
  }

  DateTime _nextDailyTrigger(DateTime now, TimeOfDay specificTime) {
    var scheduled = DateTime(
      now.year,
      now.month,
      now.day,
      specificTime.hour,
      specificTime.minute,
    );
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }

  NotificationDetails _buildAlarmNotificationDetails() {
    final vibrationPattern = Int64List.fromList([0, 1000, 500, 1000]);
    const androidChannelName = 'Medicine Alarms';
    const androidChannelDescription = 'Alerts for medication intake';

    final androidDetails = AndroidNotificationDetails(
      _androidAlarmChannelId,
      androidChannelName,
      channelDescription: androidChannelDescription,
      importance: Importance.max,
      channelBypassDnd: true,
      priority: Priority.max,
      playSound: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      vibrationPattern: vibrationPattern,
      enableVibration: true,
      fullScreenIntent: true,
      autoCancel: false,
      visibility: NotificationVisibility.public,
      category: AndroidNotificationCategory.alarm,
      actions: const <AndroidNotificationAction>[
        AndroidNotificationAction(
          _notificationActionSnooze,
          'Snooze 5 min',
          showsUserInterface: true,
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          _notificationActionDismiss,
          'Dismiss',
          showsUserInterface: true,
          cancelNotification: true,
          semanticAction: SemanticAction.delete,
        ),
      ],
    );

    return NotificationDetails(android: androidDetails);
  }

  Future<void> _scheduleSnoozeNotification({
    required String medName,
    required String dosage,
    required int? parentReminderId,
  }) async {
    await _notificationsReady;
    final snoozeId = DateTime.now().millisecondsSinceEpoch % 2147483647;
    final reminderBody = dosage.isEmpty
        ? 'Take your $medName now.'
        : 'Take your $medName ($dosage) now.';
    final payload = jsonEncode(<String, dynamic>{
      'id': parentReminderId ?? snoozeId,
      'name': medName,
      'dosage': dosage,
      'isSnooze': true,
    });

    await _notificationsPlugin.zonedSchedule(
      snoozeId,
      'Medicine Time! (Snoozed)',
      reminderBody,
      tz.TZDateTime.now(tz.local).add(const Duration(minutes: 5)),
      _buildAlarmNotificationDetails(),
      androidScheduleMode: _androidScheduleMode,
      payload: payload,
    );
  }

  Future<void> _scheduleSystemNotification(
    int notificationId,
    String medName,
    String dosage,
    int? hourInterval,
    TimeOfDay? specificTime,
  ) async {
    final platformDetails = _buildAlarmNotificationDetails();
    final reminderBody = dosage.isEmpty
        ? 'Take your $medName now.'
        : 'Take your $medName ($dosage) now.';
    final payload = jsonEncode(<String, dynamic>{
      'id': notificationId,
      'name': medName,
      'dosage': dosage,
    });

    if (specificTime != null) {
      final now = DateTime.now();
      var scheduledDate = DateTime(
        now.year,
        now.month,
        now.day,
        specificTime.hour,
        specificTime.minute,
      );

      if (scheduledDate.isBefore(now)) {
        scheduledDate = scheduledDate.add(const Duration(days: 1));
      }

      await _notificationsPlugin.zonedSchedule(
        notificationId,
        'Medicine Time!',
        reminderBody,
        tz.TZDateTime.from(scheduledDate, tz.local),
        platformDetails,
        androidScheduleMode: _androidScheduleMode,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: payload,
      );
    } else if (hourInterval != null) {
      await _notificationsPlugin.periodicallyShowWithDuration(
        notificationId,
        'Medicine Time!',
        reminderBody,
        Duration(hours: hourInterval),
        platformDetails,
        androidScheduleMode: _androidScheduleMode,
        payload: payload,
      );
    }
  }

  Map<String, dynamic>? _extractMedicineFromText(String rawText) {
    final cleaned = _sanitizeOcrText(rawText)
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return null;

    final durationInfo = _extractDurationFromText(cleaned);
    final dosage = _extractDosageFromText(cleaned);
    final quantity = _extractQuantityFromText(cleaned);
    final selectedName = _extractMedicineNameFromText(
      cleaned,
      dosageText: dosage,
      durationText: durationInfo['text'] as String? ?? '',
    );
    if (selectedName.isEmpty) return null;

    final confidence = _estimateExtractionConfidence(
      hasName: selectedName.isNotEmpty,
      hasDosage: dosage.trim().isNotEmpty,
      hasQuantity: quantity != null,
      hasTime: _extractSchedulesFromLine(cleaned).isNotEmpty,
      hasDuration: _asInt(durationInfo['days']) != null,
    );

    return <String, dynamic>{
      'name': selectedName,
      'dosage': dosage,
      'quantity': quantity,
      'durationDays': durationInfo['days'],
      'durationText': durationInfo['text'],
      'confidenceScore': confidence.$1,
      'confidenceLabel': confidence.$2,
      'rawText': cleaned,
    };
  }

  String _sanitizeOcrText(String text) {
    var normalized = text
        .replaceAll('\u2013', '-')
        .replaceAll('\u2014', '-')
        .replaceAll('\u2022', ' ')
        .replaceAll('|', '1')
        .replaceAll(RegExp(r'[ \t]+'), ' ');

    // Common OCR slips around dosage units.
    normalized = normalized.replaceAll(
      RegExp(r'(\d)\s*mq\b', caseSensitive: false),
      r'$1 mg',
    );
    normalized = normalized.replaceAll(
      RegExp(r'(\d)\s*rnl\b', caseSensitive: false),
      r'$1 ml',
    );
    normalized = normalized.replaceAll(
      RegExp(r'(\d)\s*iuu\b', caseSensitive: false),
      r'$1 iu',
    );

    return normalized;
  }

  (int, String) _estimateExtractionConfidence({
    required bool hasName,
    required bool hasDosage,
    required bool hasQuantity,
    required bool hasTime,
    required bool hasDuration,
  }) {
    var score = 0;
    if (hasName) score += 40;
    if (hasDosage) score += 20;
    if (hasQuantity) score += 10;
    if (hasTime) score += 20;
    if (hasDuration) score += 10;

    final label = score >= 80
        ? 'High'
        : score >= 60
            ? 'Medium'
            : 'Low';
    return (score, label);
  }

  Map<String, dynamic> _extractDurationFromText(String text) {
    final patterns = <RegExp>[
      RegExp(
        r'\b(?:for|x)\s*(\d{1,3})\s*(day|days|d|week|weeks|w|month|months|m)\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\b(\d{1,3})\s*(day|days|d|week|weeks|w|month|months|m)\b',
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;

      final value = int.tryParse(match.group(1) ?? '');
      final unit = (match.group(2) ?? '').toLowerCase();
      if (value == null || value <= 0) continue;

      var durationDays = value;
      if (unit.startsWith('w')) {
        durationDays = value * 7;
      } else if (unit.startsWith('m')) {
        durationDays = value * 30;
      }

      return <String, dynamic>{
        'days': durationDays,
        'text': match.group(0)!.trim(),
      };
    }

    return <String, dynamic>{
      'days': null,
      'text': '',
    };
  }

  String _extractDosageFromText(String text) {
    final explicitDosageMatch = RegExp(
      r'(\d+(?:\.\d+)?(?:\s*/\s*\d+(?:\.\d+)?)?\s*(?:mg|mcg|ug|g|gm|ml|iu|units))\b',
      caseSensitive: false,
    ).firstMatch(text);
    if (explicitDosageMatch != null) {
      return explicitDosageMatch
          .group(1)!
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    var working = text;
    working = working.replaceAll(
      RegExp(r'\b(\d{1,2})(?::(\d{2}))?\s*(AM|PM|am|pm)\b'),
      ' ',
    );
    working = working.replaceAll(
      RegExp(r'\b([0-3])\s*[-xX/]\s*([0-3])\s*[-xX/]\s*([0-3])\b'),
      ' ',
    );
    working = working.replaceAll(
      RegExp(
        r'\b(?:for|x)?\s*\d{1,3}\s*(?:day|days|d|week|weeks|w|month|months|m)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    working = working.replaceAll(
      RegExp(
        r'\b\d+\s*(tablet|tab|capsule|cap|drop|drops|puff|puffs)\b',
        caseSensitive: false,
      ),
      ' ',
    );

    final fallbackNumber =
        RegExp(r'\b(\d{2,4}(?:\.\d+)?)\b').firstMatch(working);
    if (fallbackNumber == null) return '';

    final dosageValue = fallbackNumber.group(1)!.trim();
    return '$dosageValue mg';
  }

  int? _extractQuantityFromText(String text) {
    final qtyMatch = RegExp(
      r'\b(\d+)\s*(tablet|tab|capsule|cap|drop|drops|puff|puffs)\b',
      caseSensitive: false,
    ).firstMatch(text);
    return qtyMatch != null ? int.tryParse(qtyMatch.group(1)!) : null;
  }

  String _extractMedicineNameFromText(
    String text, {
    String dosageText = '',
    String durationText = '',
  }) {
    var working = text;
    if (dosageText.trim().isNotEmpty) {
      working = working.replaceAll(
        RegExp(RegExp.escape(dosageText), caseSensitive: false),
        ' ',
      );
    }
    if (durationText.trim().isNotEmpty) {
      working = working.replaceAll(
        RegExp(RegExp.escape(durationText), caseSensitive: false),
        ' ',
      );
    }

    working = working.replaceAll(
      RegExp(r'\b(\d{1,2})(?::(\d{2}))?\s*(AM|PM|am|pm)\b'),
      ' ',
    );
    working = working.replaceAll(
      RegExp(r'\b([0-3])\s*[-xX/]\s*([0-3])\s*[-xX/]\s*([0-3])\b'),
      ' ',
    );
    working = working.replaceAll(
      RegExp(
        r'\b(?:for|x)?\s*\d{1,3}\s*(?:day|days|d|week|weeks|w|month|months|m)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    working = working.replaceAll(
      RegExp(
        r'\b\d+\s*(tablet|tab|capsule|cap|drop|drops|puff|puffs)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    working = working.replaceAll(
      RegExp(
        r'\b(morning|afternoon|noon|evening|night|bedtime|after|before|food|daily|once|twice|thrice|every|hour|hours)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    working = working.replaceAll(RegExp(r'[^A-Za-z0-9\-\s]'), ' ');

    final tokens = RegExp(
      r'\b([A-Za-z][A-Za-z0-9\-]{1,})\b',
    ).allMatches(working).map((m) => m.group(1)!).where((token) {
      return !_ocrStopWords.contains(token.toLowerCase());
    }).toList();

    if (tokens.isEmpty) return '';
    return tokens.take(4).join(' ').trim();
  }

  bool _isLikelyMedicineLine(
    String line, {
    required String name,
    required String dosage,
    int? quantity,
    int? durationDays,
  }) {
    if (name.trim().isEmpty) return false;

    final lower = line.toLowerCase();
    final nonMedicineSignals = <String>{
      'bp',
      'pulse',
      'temp',
      'temperature',
      'height',
      'weight',
      'age',
      'diagnosis',
      'complaint',
      'advice',
      'investigation',
      'doctor',
      'dr',
      'signature',
      'follow up',
      'followup',
    };
    for (final token in nonMedicineSignals) {
      if (lower.contains(token) &&
          dosage.trim().isEmpty &&
          quantity == null &&
          durationDays == null) {
        return false;
      }
    }

    if (dosage.trim().isNotEmpty) return true;
    if (quantity != null) return true;
    if (durationDays != null && durationDays > 0) return true;
    if (_extractSchedulesFromLine(line).isNotEmpty) return true;

    final nameTokens = name.split(' ').where((e) => e.trim().isNotEmpty).length;
    return nameTokens >= 1 && name.length >= 4;
  }

  List<Map<String, dynamic>> _extractSchedulesFromLine(
    String line, {
    int? fallbackQuantity,
  }) {
    final schedules = <Map<String, dynamic>>[];
    final normalizedLine = line.replaceAll('.', ':');
    final timeRegex = RegExp(r'\b(\d{1,2})(?::(\d{2}))?\s*(AM|PM|am|pm)\b');

    for (final timeMatch in timeRegex.allMatches(normalizedLine)) {
      final hour12 = int.parse(timeMatch.group(1)!);
      final minute = int.parse(timeMatch.group(2) ?? '0');
      final meridian = timeMatch.group(3)!.toUpperCase();
      var hour24 = hour12;
      if (meridian == 'PM' && hour24 != 12) hour24 += 12;
      if (meridian == 'AM' && hour24 == 12) hour24 = 0;
      schedules.add(<String, dynamic>{
        'hour': hour24,
        'minute': minute,
        'timeLabel':
            '${timeMatch.group(1)}:${timeMatch.group(2) ?? '00'} $meridian',
        'quantity': fallbackQuantity,
      });
    }
    if (schedules.isNotEmpty) return schedules;

    final twentyFourHourRegex = RegExp(r'\b([01]?\d|2[0-3])[:.]([0-5]\d)\b');
    for (final timeMatch in twentyFourHourRegex.allMatches(normalizedLine)) {
      final hour = int.parse(timeMatch.group(1)!);
      final minute = int.parse(timeMatch.group(2)!);
      schedules.add(<String, dynamic>{
        'hour': hour,
        'minute': minute,
        'timeLabel': _formatTimeLabelFrom24h(hour, minute),
        'quantity': fallbackQuantity,
      });
    }
    if (schedules.isNotEmpty) return schedules;

    final regimenMatch = RegExp(
      r'\b([0-3])\s*[-xX/]\s*([0-3])\s*[-xX/]\s*([0-3])\b',
    ).firstMatch(line);
    if (regimenMatch != null) {
      final morningCount = int.parse(regimenMatch.group(1)!);
      final noonCount = int.parse(regimenMatch.group(2)!);
      final nightCount = int.parse(regimenMatch.group(3)!);
      final slots = <(int hour, int minute, String label, int count)>[
        (8, 0, '8:00 AM', morningCount),
        (13, 0, '1:00 PM', noonCount),
        (20, 0, '8:00 PM', nightCount),
      ];

      for (final slot in slots) {
        if (slot.$4 <= 0) continue;
        schedules.add(<String, dynamic>{
          'hour': slot.$1,
          'minute': slot.$2,
          'timeLabel': slot.$3,
          'quantity': slot.$4,
        });
      }
    }
    if (schedules.isNotEmpty) return schedules;

    final lower = line.toLowerCase();
    if (RegExp(r'\b(qid|4\s*times?)\b', caseSensitive: false).hasMatch(lower)) {
      schedules.addAll(<Map<String, dynamic>>[
        <String, dynamic>{
          'hour': 8,
          'minute': 0,
          'timeLabel': '8:00 AM',
          'quantity': fallbackQuantity
        },
        <String, dynamic>{
          'hour': 12,
          'minute': 0,
          'timeLabel': '12:00 PM',
          'quantity': fallbackQuantity
        },
        <String, dynamic>{
          'hour': 16,
          'minute': 0,
          'timeLabel': '4:00 PM',
          'quantity': fallbackQuantity
        },
        <String, dynamic>{
          'hour': 22,
          'minute': 0,
          'timeLabel': '10:00 PM',
          'quantity': fallbackQuantity
        },
      ]);
    } else if (RegExp(r'\b(tds|tid|thrice|3\s*times?)\b', caseSensitive: false)
        .hasMatch(lower)) {
      schedules.addAll(<Map<String, dynamic>>[
        <String, dynamic>{
          'hour': 8,
          'minute': 0,
          'timeLabel': '8:00 AM',
          'quantity': fallbackQuantity
        },
        <String, dynamic>{
          'hour': 14,
          'minute': 0,
          'timeLabel': '2:00 PM',
          'quantity': fallbackQuantity
        },
        <String, dynamic>{
          'hour': 20,
          'minute': 0,
          'timeLabel': '8:00 PM',
          'quantity': fallbackQuantity
        },
      ]);
    } else if (RegExp(r'\b(bd|bid|twice|2\s*times?)\b', caseSensitive: false)
        .hasMatch(lower)) {
      schedules.addAll(<Map<String, dynamic>>[
        <String, dynamic>{
          'hour': 8,
          'minute': 0,
          'timeLabel': '8:00 AM',
          'quantity': fallbackQuantity
        },
        <String, dynamic>{
          'hour': 20,
          'minute': 0,
          'timeLabel': '8:00 PM',
          'quantity': fallbackQuantity
        },
      ]);
    } else if (RegExp(r'\b(od|qd|once|daily|1\s*time)\b', caseSensitive: false)
        .hasMatch(lower)) {
      final prefersNight =
          RegExp(r'\b(night|bedtime|hs)\b', caseSensitive: false)
              .hasMatch(lower);
      schedules.add(
        <String, dynamic>{
          'hour': prefersNight ? 21 : 8,
          'minute': 0,
          'timeLabel': prefersNight ? '9:00 PM' : '8:00 AM',
          'quantity': fallbackQuantity,
        },
      );
    }
    if (schedules.isNotEmpty) return schedules;

    final keywordSlots = <(String key, int hour, int minute, String label)>[
      ('morning', 8, 0, '8:00 AM'),
      ('afternoon', 13, 0, '1:00 PM'),
      ('noon', 13, 0, '1:00 PM'),
      ('evening', 18, 0, '6:00 PM'),
      ('night', 21, 0, '9:00 PM'),
      ('bedtime', 22, 0, '10:00 PM'),
    ];

    for (final slot in keywordSlots) {
      if (!lower.contains(slot.$1)) continue;
      schedules.add(<String, dynamic>{
        'hour': slot.$2,
        'minute': slot.$3,
        'timeLabel': slot.$4,
        'quantity': fallbackQuantity,
      });
    }
    return schedules;
  }

  List<Map<String, dynamic>> _parsePrescriptionText(String rawText) {
    final result = <Map<String, dynamic>>[];
    final cleanedText = _sanitizeOcrText(rawText);
    final lines = cleanedText
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    Map<String, dynamic>? pendingMedicine;
    var idCounter = 0;

    void addScheduledEntries(
      Map<String, dynamic> medDetails,
      List<Map<String, dynamic>> schedules, {
      int? overrideDurationDays,
      String overrideDurationText = '',
    }) {
      final medName = (medDetails['name'] as String? ?? '').trim();
      if (medName.isEmpty) return;

      final dosage = (medDetails['dosage'] as String? ?? '').trim();
      final baseQuantity = _asInt(medDetails['quantity']);
      final durationDays =
          overrideDurationDays ?? _asInt(medDetails['durationDays']);
      final durationText = overrideDurationText.trim().isNotEmpty
          ? overrideDurationText.trim()
          : (medDetails['durationText'] as String? ?? '').trim();

      for (final schedule in schedules) {
        final hour = _asInt(schedule['hour']);
        final minute = _asInt(schedule['minute']);
        if (hour == null || minute == null) continue;

        final scheduleQuantity = _asInt(schedule['quantity']);
        final id = (DateTime.now().millisecondsSinceEpoch + idCounter)
            .remainder(2147483647);
        idCounter += 1;
        final confidence = _estimateExtractionConfidence(
          hasName: medName.isNotEmpty,
          hasDosage: dosage.isNotEmpty,
          hasQuantity: (scheduleQuantity ?? baseQuantity) != null,
          hasTime: true,
          hasDuration: durationText.isNotEmpty || (durationDays ?? 0) > 0,
        );

        result.add(<String, dynamic>{
          'id': id,
          'name': medName,
          'dosage': dosage,
          'quantity': scheduleQuantity ?? baseQuantity,
          'durationDays': durationDays,
          'durationText': durationText,
          'hour': hour,
          'minute': minute,
          'timeLabel': schedule['timeLabel'],
          'confidenceScore': confidence.$1,
          'confidenceLabel': confidence.$2,
        });
      }
    }

    void addUnscheduledEntry(
      Map<String, dynamic> medDetails, {
      int? overrideDurationDays,
      String overrideDurationText = '',
      int? confidenceScore,
      String confidenceLabel = 'Low',
    }) {
      final medName = (medDetails['name'] as String? ?? '').trim();
      if (medName.isEmpty) return;

      final dosage = (medDetails['dosage'] as String? ?? '').trim();
      final quantity = _asInt(medDetails['quantity']);
      final durationDays =
          overrideDurationDays ?? _asInt(medDetails['durationDays']);
      final durationText = overrideDurationText.trim().isNotEmpty
          ? overrideDurationText.trim()
          : (medDetails['durationText'] as String? ?? '').trim();

      final id = (DateTime.now().millisecondsSinceEpoch + idCounter)
          .remainder(2147483647);
      idCounter += 1;

      result.add(<String, dynamic>{
        'id': id,
        'name': medName,
        'dosage': dosage,
        'quantity': quantity,
        'durationDays': durationDays,
        'durationText': durationText,
        'hour': null,
        'minute': null,
        'timeLabel': 'Not set',
        'confidenceScore': confidenceScore ?? 45,
        'confidenceLabel': confidenceLabel,
      });
    }

    for (final line in lines) {
      final durationInfo = _extractDurationFromText(line);
      final durationDays = _asInt(durationInfo['days']);
      final durationText = (durationInfo['text'] as String? ?? '').trim();
      final dosageText = _extractDosageFromText(line);
      final quantity = _extractQuantityFromText(line);
      final nameText = _extractMedicineNameFromText(
        line,
        dosageText: dosageText,
        durationText: durationText,
      );

      final hasMedicine = nameText.isNotEmpty;
      final activeMedicine = hasMedicine
          ? <String, dynamic>{
              'name': nameText,
              'dosage': dosageText,
              'quantity': quantity,
              'durationDays': durationDays,
              'durationText': durationText,
            }
          : null;

      final schedules = _extractSchedulesFromLine(
        line,
        fallbackQuantity: quantity ?? _asInt(pendingMedicine?['quantity']),
      );

      if (activeMedicine != null && schedules.isNotEmpty) {
        addScheduledEntries(activeMedicine, schedules);
        pendingMedicine = null;
        continue;
      }

      if (activeMedicine != null && schedules.isEmpty) {
        pendingMedicine = activeMedicine;
        continue;
      }

      if (activeMedicine == null &&
          schedules.isNotEmpty &&
          pendingMedicine != null) {
        addScheduledEntries(
          pendingMedicine,
          schedules,
          overrideDurationDays: durationDays,
          overrideDurationText: durationText,
        );
        pendingMedicine = null;
        continue;
      }

      if (activeMedicine == null && pendingMedicine != null) {
        if (durationDays != null) {
          pendingMedicine['durationDays'] = durationDays;
        }
        if (durationText.isNotEmpty) {
          pendingMedicine['durationText'] = durationText;
        }
      }
    }

    if (pendingMedicine != null) {
      addUnscheduledEntry(
        pendingMedicine,
        confidenceScore: 45,
        confidenceLabel: 'Low',
      );
    }

    if (result.isEmpty) {
      final chunks = cleanedText
          .split(RegExp(r'[;,]'))
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList();

      for (final chunk in chunks) {
        final durationInfo = _extractDurationFromText(chunk);
        final dosageText = _extractDosageFromText(chunk);
        final quantity = _extractQuantityFromText(chunk);
        final nameText = _extractMedicineNameFromText(
          chunk,
          dosageText: dosageText,
          durationText: (durationInfo['text'] as String? ?? '').trim(),
        );
        if (nameText.isEmpty) continue;

        final schedules = _extractSchedulesFromLine(
          chunk,
          fallbackQuantity: quantity,
        );
        if (schedules.isEmpty) continue;

        addScheduledEntries(
          <String, dynamic>{
            'name': nameText,
            'dosage': dosageText,
            'quantity': quantity,
            'durationDays': durationInfo['days'],
            'durationText': durationInfo['text'],
          },
          schedules,
        );
      }
    }

    if (result.isEmpty) {
      for (final line in lines) {
        final durationInfo = _extractDurationFromText(line);
        final durationDays = _asInt(durationInfo['days']);
        final durationText = (durationInfo['text'] as String? ?? '').trim();
        final dosageText = _extractDosageFromText(line);
        final quantity = _extractQuantityFromText(line);
        final nameText = _extractMedicineNameFromText(
          line,
          dosageText: dosageText,
          durationText: durationText,
        );
        if (!_isLikelyMedicineLine(
          line,
          name: nameText,
          dosage: dosageText,
          quantity: quantity,
          durationDays: durationDays,
        )) {
          continue;
        }

        final schedules = _extractSchedulesFromLine(
          line,
          fallbackQuantity: quantity,
        );
        if (schedules.isNotEmpty) {
          addScheduledEntries(
            <String, dynamic>{
              'name': nameText,
              'dosage': dosageText,
              'quantity': quantity,
              'durationDays': durationDays,
              'durationText': durationText,
            },
            schedules,
          );
        } else {
          addUnscheduledEntry(
            <String, dynamic>{
              'name': nameText,
              'dosage': dosageText,
              'quantity': quantity,
              'durationDays': durationDays,
              'durationText': durationText,
            },
            confidenceScore: 45,
            confidenceLabel: 'Low',
          );
        }
      }
    }

    return result;
  }

  String _normalize(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  Set<String> _tokenizeForMatching(String value) {
    return RegExp(
      r'\b([A-Za-z][A-Za-z0-9\-]{1,})\b',
    ).allMatches(value).map((m) => m.group(1)!.toLowerCase()).where((token) {
      return !_ocrStopWords.contains(token);
    }).toSet();
  }

  int _nameSimilarityScore(String scannedName, String prescribedName) {
    final normalizedScan = _normalize(scannedName);
    final normalizedPrescribed = _normalize(prescribedName);
    if (normalizedScan.isEmpty || normalizedPrescribed.isEmpty) return 0;

    if (normalizedScan == normalizedPrescribed) return 120;
    if (normalizedPrescribed.contains(normalizedScan) ||
        normalizedScan.contains(normalizedPrescribed)) {
      return 85;
    }

    final scanTokens = _tokenizeForMatching(scannedName);
    final prescribedTokens = _tokenizeForMatching(prescribedName);
    if (scanTokens.isEmpty || prescribedTokens.isEmpty) return 0;

    final commonTokens = scanTokens.intersection(prescribedTokens).length;
    if (commonTokens == 0) return 0;

    final score =
        (commonTokens * 35) - ((prescribedTokens.length - commonTokens) * 3);
    return score > 0 ? score : 0;
  }

  int _bestCandidateScore({
    required String scannedName,
    required Map<String, dynamic> candidate,
    String scannedRawText = '',
  }) {
    final prescribedName = (candidate['name'] as String? ?? '').trim();
    if (prescribedName.isEmpty) return 0;

    var score = _nameSimilarityScore(scannedName, prescribedName);
    if (scannedRawText.trim().isNotEmpty) {
      final rawScore = _nameSimilarityScore(scannedRawText, prescribedName);
      if (rawScore > score) score = rawScore;
    }
    return score;
  }

  Map<String, dynamic>? _findBestPrescriptionMatch({
    required String scannedName,
    required Iterable<Map<String, dynamic>> candidates,
    String scannedRawText = '',
  }) {
    Map<String, dynamic>? bestMatch;
    var bestScore = 0;

    for (final candidate in candidates) {
      final score = _bestCandidateScore(
        scannedName: scannedName,
        candidate: candidate,
        scannedRawText: scannedRawText,
      );
      if (score <= 0) continue;

      if (score > bestScore) {
        bestScore = score;
        bestMatch = candidate;
      }
    }

    return bestScore >= _smartMatchThreshold ? bestMatch : null;
  }

  List<Map<String, dynamic>> _findTopPrescriptionMatches({
    required String scannedName,
    required Iterable<Map<String, dynamic>> candidates,
    String scannedRawText = '',
    int limit = 3,
  }) {
    final scored = <Map<String, dynamic>>[];
    for (final candidate in candidates) {
      final score = _bestCandidateScore(
        scannedName: scannedName,
        candidate: candidate,
        scannedRawText: scannedRawText,
      );
      if (score < _smartStrongMatchThreshold) continue;
      final enriched = Map<String, dynamic>.from(candidate);
      enriched['smartMatchScore'] = score;
      scored.add(enriched);
    }

    scored.sort((a, b) {
      final aScore = _asInt(a['smartMatchScore']) ?? 0;
      final bScore = _asInt(b['smartMatchScore']) ?? 0;
      return bScore.compareTo(aScore);
    });

    if (scored.length <= limit) return scored;
    return scored.sublist(0, limit);
  }

  bool _isDosageCompatible(String prescribedDosage, String scannedDosage) {
    final prescribed = _normalize(prescribedDosage);
    final scanned = _normalize(scannedDosage);
    if (prescribed.isEmpty || scanned.isEmpty) return true;
    if (prescribed == scanned) return true;
    if (prescribed.contains(scanned) || scanned.contains(prescribed)) {
      return true;
    }

    final prescribedNumbers = RegExp(r'\d+(?:\.\d+)?')
        .allMatches(prescribedDosage)
        .map((m) => m.group(0)!)
        .toSet();
    final scannedNumbers = RegExp(r'\d+(?:\.\d+)?')
        .allMatches(scannedDosage)
        .map((m) => m.group(0)!)
        .toSet();

    if (prescribedNumbers.isNotEmpty &&
        scannedNumbers.isNotEmpty &&
        prescribedNumbers.intersection(scannedNumbers).isNotEmpty) {
      return true;
    }
    return false;
  }

  bool _isQuantityCompatible(int? prescribedQty, int? scannedQty) {
    return prescribedQty == null ||
        scannedQty == null ||
        prescribedQty == scannedQty;
  }

  String _formatTimeLabelFrom24h(int hour, int minute) {
    final suffix = hour >= 12 ? 'PM' : 'AM';
    final hour12 = hour % 12 == 0 ? 12 : hour % 12;
    return '$hour12:${minute.toString().padLeft(2, '0')} $suffix';
  }

  String _formatScheduleTime(Map<String, dynamic> med) {
    final label = (med['timeLabel'] as String? ?? '').trim();
    if (label.isNotEmpty) return label;

    final hour = _asInt(med['hour']);
    final minute = _asInt(med['minute']);
    if (hour == null || minute == null) return 'scheduled time';
    return _formatTimeLabelFrom24h(hour, minute);
  }

  String _displayTimeLabel(Map<String, dynamic> med) {
    final label = (med['timeLabel'] as String? ?? '').trim();
    if (label.isNotEmpty) return label;
    final hour = _asInt(med['hour']);
    final minute = _asInt(med['minute']);
    if (hour == null || minute == null) return 'Not set';
    return _formatTimeLabelFrom24h(hour, minute);
  }

  String _formatMedicineInstruction(
    Map<String, dynamic> med, {
    bool includeTime = false,
  }) {
    final name = (med['name'] as String? ?? 'Medicine').trim();
    final dosage = (med['dosage'] as String? ?? '').trim();
    final quantity = _asInt(med['quantity']);
    final durationDays = _asInt(med['durationDays']);
    final durationText = (med['durationText'] as String? ?? '').trim();

    final buffer = StringBuffer(name);
    if (dosage.isNotEmpty) {
      buffer.write(' $dosage');
    }
    if (quantity != null) {
      buffer.write(' (Qty $quantity)');
    }
    if (durationText.isNotEmpty) {
      buffer.write(' [$durationText]');
    } else if (durationDays != null && durationDays > 0) {
      buffer.write(' [$durationDays days]');
    }
    if (includeTime) {
      buffer.write(' at ${_formatScheduleTime(med)}');
    }
    return buffer.toString();
  }

  String _formatDueSuggestion(List<Map<String, dynamic>> meds) {
    if (meds.isEmpty) return 'the scheduled medicine';
    return meds
        .map((med) => _formatMedicineInstruction(med, includeTime: true))
        .join(', ');
  }

  int? _minutesFromScheduledNow(Map<String, dynamic> med, DateTime now) {
    final hour = _asInt(med['hour']);
    final minute = _asInt(med['minute']);
    if (hour == null || minute == null) return null;

    final scheduled = DateTime(now.year, now.month, now.day, hour, minute);
    return now.difference(scheduled).inMinutes;
  }

  bool _isDueNow(Map<String, dynamic> med) {
    final now = DateTime.now();
    final diffMinutes = _minutesFromScheduledNow(med, now);
    if (diffMinutes == null) return false;
    return diffMinutes.abs() <= _dueWindowMinutes;
  }

  List<Map<String, dynamic>> _dueMedicinesNow(DateTime now) {
    final due = _prescriptionEntries.where(_isDueNow).toList();

    due.sort((a, b) {
      final aDiff = (_minutesFromScheduledNow(a, now) ?? 99999).abs();
      final bDiff = (_minutesFromScheduledNow(b, now) ?? 99999).abs();
      return aDiff.compareTo(bDiff);
    });
    return due;
  }

  DateTime? _nextOccurrence(Map<String, dynamic> med, DateTime now) {
    final hour = _asInt(med['hour']);
    final minute = _asInt(med['minute']);
    if (hour == null || minute == null) return null;

    var next = DateTime(now.year, now.month, now.day, hour, minute);
    if (!next.isAfter(now)) {
      next = next.add(const Duration(days: 1));
    }
    return next;
  }

  List<Map<String, dynamic>> _upcomingMedicines(
    DateTime now, {
    int? limit,
  }) {
    final maxCount = limit ?? _upcomingSuggestionCount;
    final upcoming = _prescriptionEntries.where((entry) {
      return _nextOccurrence(entry, now) != null;
    }).toList();

    upcoming.sort((a, b) {
      final aNext = _nextOccurrence(a, now)!;
      final bNext = _nextOccurrence(b, now)!;
      return aNext.compareTo(bNext);
    });

    if (upcoming.length > maxCount) {
      return upcoming.sublist(0, maxCount);
    }
    return upcoming;
  }

  String _formatUpcomingSuggestion(List<Map<String, dynamic>> meds) {
    if (meds.isEmpty) return '';
    return meds
        .map((med) => _formatMedicineInstruction(med, includeTime: true))
        .join(', ');
  }

  int _entryConfidenceScore(Map<String, dynamic> entry) {
    return _asInt(entry['confidenceScore']) ??
        _estimateExtractionConfidence(
          hasName: ((entry['name'] as String?) ?? '').trim().isNotEmpty,
          hasDosage: ((entry['dosage'] as String?) ?? '').trim().isNotEmpty,
          hasQuantity: _asInt(entry['quantity']) != null,
          hasTime:
              _asInt(entry['hour']) != null && _asInt(entry['minute']) != null,
          hasDuration:
              ((entry['durationText'] as String?) ?? '').trim().isNotEmpty ||
                  ((_asInt(entry['durationDays']) ?? 0) > 0),
        ).$1;
  }

  String _entryConfidenceLabel(Map<String, dynamic> entry) {
    final stored = (entry['confidenceLabel'] as String? ?? '').trim();
    if (stored.isNotEmpty) return stored;
    final score = _entryConfidenceScore(entry);
    if (score >= 80) return 'High';
    if (score >= 60) return 'Medium';
    return 'Low';
  }

  int _countLowConfidenceEntries(List<Map<String, dynamic>> entries) {
    return entries.where((entry) => _entryConfidenceScore(entry) < 60).length;
  }

  Future<ImageSource?> _pickImageSource({
    required String title,
  }) async {
    return showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(title),
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Use Camera'),
                onTap: () => Navigator.pop(sheetContext, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose From Gallery'),
                onTap: () => Navigator.pop(sheetContext, ImageSource.gallery),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _startPrescriptionScan() async {
    final source = await _pickImageSource(
      title: 'Scan Prescription From',
    );
    if (source == null) return;
    await _scanPrescription(source);
  }

  Future<void> _startStripVerificationScan() async {
    final source = await _pickImageSource(
      title: 'Verify Strip From',
    );
    if (source == null) return;
    await _scanMedicineStrip(source);
  }

  Future<void> _saveConfirmedPrescription({
    required List<Map<String, dynamic>> parsedEntries,
    required String extractedText,
  }) async {
    var notificationFailures = 0;
    var unscheduledEntries = 0;
    final cleanedText = extractedText.trim();

    try {
      await _notificationsReady;

      for (final old in _prescriptionEntries) {
        final oldId = _asInt(old['id']);
        if (oldId == null) continue;
        try {
          await _notificationsPlugin.cancel(oldId);
          _lastShownSlotByReminderId.remove(oldId);
        } catch (error) {
          notificationFailures += 1;
          debugPrint('Failed to cancel old reminder $oldId: $error');
        }
      }

      for (final med in parsedEntries) {
        final id = _asInt(med['id']) ??
            (DateTime.now().millisecondsSinceEpoch % 2147483647);
        final hour = _asInt(med['hour']);
        final minute = _asInt(med['minute']);
        final name = (med['name'] as String? ?? '').trim();
        if (name.isEmpty) {
          notificationFailures += 1;
          continue;
        }
        if (hour == null || minute == null) {
          unscheduledEntries += 1;
          continue;
        }

        try {
          await _scheduleSystemNotification(
            id,
            name,
            med['dosage'] as String? ?? '',
            null,
            TimeOfDay(hour: hour, minute: minute),
          );
        } catch (error) {
          notificationFailures += 1;
          debugPrint('Failed to schedule reminder for $name: $error');
        }
      }
    } catch (error) {
      notificationFailures += 1;
      debugPrint('Notification setup failed: $error');
    }

    try {
      await _persistPrescription(parsedEntries);
      await _persistExtractedPrescriptionText(cleanedText);
    } catch (error) {
      debugPrint('Failed to save prescription locally: $error');
      if (!mounted) return;
      setState(() {
        _resultText =
            'Could not save prescription locally. Please try again with a shorter extracted text.';
      });
      await _flutterTts.speak('Could not save prescription locally.');
      return;
    }

    if (!mounted) return;
    final lowConfidenceCount = _countLowConfidenceEntries(parsedEntries);
    setState(() {
      _prescriptionEntries
        ..clear()
        ..addAll(parsedEntries);
      _lastExtractedPrescriptionText = cleanedText;
      _resultText = notificationFailures == 0
          ? 'Prescription confirmed and saved locally with ${parsedEntries.length} medicine entries.'
          : 'Prescription saved locally with ${parsedEntries.length} entries, but some reminders could not be scheduled.';
      if (unscheduledEntries > 0) {
        _resultText =
            '$_resultText $unscheduledEntries entr${unscheduledEntries == 1 ? 'y has' : 'ies have'} no time set, so reminders were skipped.';
      }
      if (lowConfidenceCount > 0) {
        _resultText =
            '$_resultText Smart warning: $lowConfidenceCount entr${lowConfidenceCount == 1 ? 'y' : 'ies'} had low extraction confidence.';
      }
    });

    var speech = notificationFailures == 0
        ? 'Prescription confirmed and saved with ${parsedEntries.length} medicines.'
        : 'Prescription saved, but some reminders could not be scheduled.';
    if (lowConfidenceCount > 0) {
      speech =
          '$speech Warning. $lowConfidenceCount ${lowConfidenceCount == 1 ? 'entry has' : 'entries have'} low confidence. Please verify medicine details.';
    }
    if (unscheduledEntries > 0) {
      speech =
          '$speech $unscheduledEntries ${unscheduledEntries == 1 ? 'entry has' : 'entries have'} no time set.';
    }
    await _flutterTts.speak(speech);
  }

  Future<void> _reviewAndStorePrescription(String extractedText) async {
    final reviewedText = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return _PrescriptionReviewDialog(
          initialText: extractedText,
          parser: _parsePrescriptionText,
        );
      },
    );

    // Let the dialog route fully teardown before touching parent UI state.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (reviewedText == null) {
      if (!mounted) return;
      setState(() {
        _resultText =
            'Prescription was not saved. Please rescan or edit the extracted text.';
      });
      await _flutterTts.speak('Prescription not saved.');
      return;
    }

    final parsedPreview = _parsePrescriptionText(reviewedText);
    if (parsedPreview.isEmpty) {
      if (mounted) {
        setState(() {
          _resultText =
              'Could not parse medicine schedules from the confirmed text. Please edit and include medicine time details.';
        });
      }
      await _flutterTts.speak('Could not parse medicine schedule from text.');
      return;
    }

    await _saveConfirmedPrescription(
      parsedEntries: parsedPreview,
      extractedText: reviewedText,
    );
  }

  Future<void> _scanPrescription(ImageSource source) async {
    final pickedFile = await ImagePicker().pickImage(source: source);
    if (pickedFile == null) return;

    setState(() => _image = File(pickedFile.path));
    final recognizedText =
        await _textRecognizer.processImage(InputImage.fromFile(_image!));
    final extractedText = _sanitizeOcrText(recognizedText.text).trim();
    if (extractedText.isEmpty) {
      setState(() {
        _resultText =
            'No text detected from prescription. Please capture a clearer image.';
      });
      await _flutterTts.speak('No text detected from prescription image.');
      return;
    }

    setState(() {
      _lastExtractedPrescriptionText = extractedText;
      _resultText =
          'Smart scan complete. Prescription text extracted. Please review and confirm details.';
    });

    await _flutterTts.speak(
        'Smart scan complete. Prescription text extracted. Please confirm details.');
    await _reviewAndStorePrescription(extractedText);
  }

  Future<void> _scanMedicineStrip(ImageSource source) async {
    final pickedFile = await ImagePicker().pickImage(source: source);
    if (pickedFile == null) return;

    setState(() => _image = File(pickedFile.path));
    final recognizedText =
        await _textRecognizer.processImage(InputImage.fromFile(_image!));
    final stripMed = _extractMedicineFromText(recognizedText.text);

    if (_prescriptionEntries.isEmpty) {
      setState(() {
        _resultText = 'No saved prescription. Scan prescription first.';
      });
      await _flutterTts
          .speak('No stored prescription. Please scan prescription first.');
      return;
    }

    if (stripMed == null) {
      setState(() {
        _resultText = 'Could not read medicine name from strip.';
      });
      await _flutterTts.speak('I could not read medicine details from strip.');
      return;
    }

    final stripName = (stripMed['name'] as String? ?? '').trim();
    final stripDosage = (stripMed['dosage'] as String? ?? '').trim();
    final stripQty = _asInt(stripMed['quantity']);
    final stripRawText = (stripMed['rawText'] as String? ?? '').trim();
    final now = DateTime.now();

    final dueNow = _dueMedicinesNow(now);
    final dueMatch = _findBestPrescriptionMatch(
      scannedName: stripName,
      scannedRawText: stripRawText,
      candidates: dueNow,
    );
    final anyMatch = _findBestPrescriptionMatch(
      scannedName: stripName,
      scannedRawText: stripRawText,
      candidates: _prescriptionEntries,
    );
    final topCandidates = _findTopPrescriptionMatches(
      scannedName: stripName,
      scannedRawText: stripRawText,
      candidates: _prescriptionEntries,
      limit: 2,
    );

    String verdict;
    if (dueNow.isEmpty) {
      if (anyMatch != null) {
        final nextTime = _nextOccurrence(anyMatch, now);
        final nextLabel = nextTime != null
            ? _formatTimeLabelFrom24h(nextTime.hour, nextTime.minute)
            : _formatScheduleTime(anyMatch);
        verdict =
            'No medicine is due right now. ${anyMatch['name']} is in your prescription and is next at $nextLabel.';
      } else {
        verdict = 'No medicine is due right now.';
      }

      final upcoming = _formatUpcomingSuggestion(_upcomingMedicines(now));
      if (upcoming.isNotEmpty) {
        verdict = '$verdict Next scheduled medicine: $upcoming.';
      }
    } else if (dueMatch == null) {
      verdict =
          'This strip is not the correct medicine for now. Please take ${_formatDueSuggestion(dueNow)}.';
      if (anyMatch != null && !dueNow.contains(anyMatch)) {
        final scheduledTime = _nextOccurrence(anyMatch, now);
        final label = scheduledTime != null
            ? _formatTimeLabelFrom24h(scheduledTime.hour, scheduledTime.minute)
            : _formatScheduleTime(anyMatch);
        verdict = '$verdict ${anyMatch['name']} is scheduled at $label.';
      }
      if (topCandidates.isNotEmpty) {
        final smartSuggestion = topCandidates
            .map((m) => _formatMedicineInstruction(m, includeTime: true))
            .join(', ');
        verdict = '$verdict Smart suggestion: did you mean $smartSuggestion?';
      }
    } else {
      final prescribedDosage = (dueMatch['dosage'] as String? ?? '').trim();
      final prescribedQty = _asInt(dueMatch['quantity']);

      final dosageOk = _isDosageCompatible(prescribedDosage, stripDosage);
      final quantityOk = _isQuantityCompatible(prescribedQty, stripQty);
      final correctNow =
          _formatMedicineInstruction(dueMatch, includeTime: true);

      if (dosageOk && quantityOk) {
        verdict = 'Correct medicine for this time. Take $correctNow.';
      } else {
        final mismatch = <String>[];
        if (!dosageOk) mismatch.add('dosage');
        if (!quantityOk) mismatch.add('quantity');
        verdict =
            'Medicine name matches, but ${mismatch.join(' and ')} does not match prescription. Correct now: $correctNow.';
      }

      if (dueNow.length > 1) {
        final others =
            dueNow.where((med) => med['id'] != dueMatch['id']).toList();
        if (others.isNotEmpty) {
          verdict = '$verdict Also due now: ${_formatDueSuggestion(others)}.';
        }
      }
    }

    final confidenceLabel =
        (stripMed['confidenceLabel'] as String? ?? '').trim();
    final confidenceScore = _asInt(stripMed['confidenceScore']);
    if (confidenceLabel.isNotEmpty && confidenceScore != null) {
      verdict =
          '$verdict Scanner confidence: $confidenceLabel ($confidenceScore%).';
    }

    setState(() {
      _resultText = verdict;
    });
    await _flutterTts.speak(verdict);
  }

  Widget _buildPrimaryActionButton({
    required String label,
    required String semanticLabel,
    required IconData icon,
    required VoidCallback onPressed,
    required Color backgroundColor,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: Semantics(
        button: true,
        label: semanticLabel,
        child: ElevatedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 24),
          label: Text(label),
          style: ElevatedButton.styleFrom(
            backgroundColor: backgroundColor,
            foregroundColor: _mrdActionTextColor,
            elevation: 2,
            shadowColor: Colors.black.withValues(alpha: 0.25),
            textStyle: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.1,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(
                color: Color(0xFF0F172A),
                width: 1.2,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF0A5A36), size: 24),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111827),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyStateCard(String message) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.info_outline, color: Color(0xFF475569)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF334155),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDistinguishedSection({
    required String title,
    required String tag,
    required IconData icon,
    required Color accentColor,
    required Color backgroundColor,
    required Widget child,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accentColor, width: 1.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: accentColor, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  tag,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Medicine Assistant'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
            icon: const Icon(Icons.settings),
          ),
          IconButton(
            tooltip:
                _showReliabilityCheck ? 'Hide Alarm Check' : 'Show Alarm Check',
            onPressed: () async {
              final shouldShow = !_showReliabilityCheck;
              setState(() => _showReliabilityCheck = shouldShow);
              if (shouldShow) {
                await _refreshAlarmReliabilityStatus();
              }
            },
            icon: Icon(
              _showReliabilityCheck
                  ? Icons.health_and_safety
                  : Icons.health_and_safety_outlined,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          children: [
            if (_image != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  _image!,
                  height: 160,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 10),
            ],
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSectionHeader('Quick Actions', Icons.touch_app_rounded),
                    const SizedBox(height: 10),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final halfWidth = (constraints.maxWidth - 10) / 2;
                        return Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            SizedBox(
                              width: halfWidth,
                              child: _buildPrimaryActionButton(
                                label: 'Scan',
                                semanticLabel:
                                    'Scan prescription using camera or gallery',
                                icon: Icons.document_scanner,
                                onPressed: _startPrescriptionScan,
                                backgroundColor: _mrdScanButtonColor,
                              ),
                            ),
                            SizedBox(
                              width: halfWidth,
                              child: _buildPrimaryActionButton(
                                label: 'Verify',
                                semanticLabel:
                                    'Verify medicine strip against due medicines',
                                icon: Icons.medication,
                                onPressed: _startStripVerificationScan,
                                backgroundColor: _mrdVerifyButtonColor,
                              ),
                            ),
                            SizedBox(
                              width: constraints.maxWidth,
                              child: _buildPrimaryActionButton(
                                label: 'Manual Reminder Entry',
                                semanticLabel: 'Add medicine reminder manually',
                                icon: Icons.edit_note,
                                onPressed: () => _showManualEntryDialog(),
                                backgroundColor: _mrdManualButtonColor,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              margin: EdgeInsets.zero,
              color: const Color(0xFFEFF6FF),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.record_voice_over_rounded,
                      color: Color(0xFF1E40AF),
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _resultText,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                          color: const Color(0xFF1E3A8A),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_lastExtractedPrescriptionText.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Last Extracted Prescription Text',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 80,
                        child: SingleChildScrollView(
                          child: Text(
                            _lastExtractedPrescriptionText,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_showReliabilityCheck) ...[
              const SizedBox(height: 10),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Alarm Reliability Check',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Refresh Status',
                            onPressed: _isReliabilityStatusLoading
                                ? null
                                : _refreshAlarmReliabilityStatus,
                            icon: _isReliabilityStatusLoading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child:
                                        CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.refresh),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            onPressed: () {
                              setState(() => _showReliabilityCheck = false);
                            },
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      _buildReliabilityRow(
                        label: 'Notifications',
                        status: _notificationsEnabled,
                        onPressed: () => _requestNotificationsPermission(),
                      ),
                      _buildReliabilityRow(
                        label: 'Exact Alarm',
                        status: _exactAlarmEnabled,
                        onPressed: () => _requestExactAlarmPermission(),
                      ),
                      _buildReliabilityRow(
                        label: 'Full-screen Intent',
                        status: _fullScreenIntentEnabled,
                        unknownText: 'Tap Grant',
                        onPressed: () => _requestFullScreenIntentPermission(),
                      ),
                      _buildReliabilityRow(
                        label: 'DND Bypass',
                        status: _dndBypassEnabled,
                        onPressed: () => _requestDndBypassPermission(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            _buildDistinguishedSection(
              title: 'Saved Prescription Medicines',
              tag: 'Prescription',
              icon: Icons.schedule_rounded,
              accentColor: const Color(0xFF0B3A8A),
              backgroundColor: const Color(0xFFEAF2FF),
              child: _prescriptionEntries.isEmpty
                  ? _buildEmptyStateCard(
                      'No prescription medicines saved yet. Tap "Scan" to begin.',
                    )
                  : Column(
                      children: _prescriptionEntries.map((item) {
                        final timeLabel = _displayTimeLabel(item);
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: const BorderSide(
                              color: Color(0xFFBFDBFE),
                            ),
                          ),
                          child: ListTile(
                            leading: const CircleAvatar(
                              backgroundColor: Color(0xFFD1FAE5),
                              child: Icon(Icons.schedule, color: Color(0xFF065F46)),
                            ),
                            title: Text(
                              '${item['name']} ${item['dosage']}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            subtitle: Text(
                              'Qty: ${item['quantity'] ?? '-'} | Duration: ${item['durationText'] ?? '-'}\nTime: $timeLabel | Confidence: ${_entryConfidenceLabel(item)}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
            ),
            _buildDistinguishedSection(
              title: 'Active Reminders',
              tag: 'Reminders',
              icon: Icons.alarm_rounded,
              accentColor: const Color(0xFF7E22CE),
              backgroundColor: const Color(0xFFF5ECFF),
              child: _myReminders.isEmpty
                  ? _buildEmptyStateCard(
                      'No active reminders. Use "Manual Reminder Entry" to add one.',
                    )
                  : Column(
                      children: _myReminders.asMap().entries.map((entry) {
                        final index = entry.key;
                        final item = entry.value;
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: const BorderSide(
                              color: Color(0xFFE9D5FF),
                            ),
                          ),
                          child: ListTile(
                            leading: const CircleAvatar(
                              backgroundColor: Color(0xFFFAE8FF),
                              child: Icon(Icons.medication, color: Color(0xFF7E22CE)),
                            ),
                            title: Text(
                              '${item['name']} (${item['dosage']})',
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                            subtitle: Text(item['time'] as String),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Edit reminder',
                                  icon: const Icon(Icons.edit, color: Colors.blue),
                                  onPressed: () => _showManualEntryDialog(index: index),
                                ),
                                IconButton(
                                  tooltip: 'Delete reminder',
                                  icon: const Icon(Icons.delete, color: Colors.red),
                                  onPressed: () async {
                                    final removedId = item['id'] as int;
                                    setState(() => _myReminders.removeAt(index));
                                    _lastShownSlotByReminderId.remove(removedId);
                                    await _notificationsPlugin.cancel(removedId);
                                    await _persistManualReminders();
                                    _flutterTts.speak('Deleted ${item['name']}');
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrescriptionReviewDialog extends StatefulWidget {
  final String initialText;
  final List<Map<String, dynamic>> Function(String text) parser;

  const _PrescriptionReviewDialog({
    required this.initialText,
    required this.parser,
  });

  @override
  State<_PrescriptionReviewDialog> createState() =>
      _PrescriptionReviewDialogState();
}

class _PrescriptionReviewDialogState extends State<_PrescriptionReviewDialog> {
  late final TextEditingController _controller;
  late List<Map<String, dynamic>> _parsedPreview;

  int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  String _formatTimeLabelFrom24h(int hour, int minute) {
    final suffix = hour >= 12 ? 'PM' : 'AM';
    final hour12 = hour % 12 == 0 ? 12 : hour % 12;
    return '$hour12:${minute.toString().padLeft(2, '0')} $suffix';
  }

  String _displayTimeLabel(Map<String, dynamic> med) {
    final label = (med['timeLabel'] as String? ?? '').trim();
    if (label.isNotEmpty) return label;
    final hour = _asInt(med['hour']);
    final minute = _asInt(med['minute']);
    if (hour == null || minute == null) return 'Not set';
    return _formatTimeLabelFrom24h(hour, minute);
  }

  int _entryConfidenceScore(Map<String, dynamic> entry) {
    final scoreRaw = entry['confidenceScore'];
    if (scoreRaw is int) return scoreRaw;
    if (scoreRaw is double) return scoreRaw.toInt();
    if (scoreRaw is String) return int.tryParse(scoreRaw) ?? 0;

    var score = 0;
    if (((entry['name'] as String?) ?? '').trim().isNotEmpty) score += 40;
    if (((entry['dosage'] as String?) ?? '').trim().isNotEmpty) score += 20;
    if (entry['quantity'] != null) score += 10;
    if (entry['hour'] != null && entry['minute'] != null) score += 20;
    if (((entry['durationText'] as String?) ?? '').trim().isNotEmpty ||
        ((entry['durationDays'] as int?) ?? 0) > 0) {
      score += 10;
    }
    return score;
  }

  String _entryConfidenceLabel(Map<String, dynamic> entry) {
    final label = (entry['confidenceLabel'] as String? ?? '').trim();
    if (label.isNotEmpty) return label;

    final score = _entryConfidenceScore(entry);
    if (score >= 80) return 'High';
    if (score >= 60) return 'Medium';
    return 'Low';
  }

  @override
  void initState() {
    super.initState();
    final initial = widget.initialText.trim();
    _controller = TextEditingController(text: initial);
    _parsedPreview = widget.parser(initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final previewItems = _parsedPreview.take(6).toList();
    final lowConfidenceCount = _parsedPreview
        .where((entry) => _entryConfidenceScore(entry) < 60)
        .length;

    return AlertDialog(
      title: const Text('Confirm Extracted Prescription'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Review and edit extracted text before saving.',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _controller,
                minLines: 5,
                maxLines: 10,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Extracted prescription text',
                ),
                onChanged: (value) {
                  if (!mounted) return;
                  setState(() {
                    _parsedPreview = widget.parser(value.trim());
                  });
                },
              ),
              const SizedBox(height: 10),
              Text(
                'Detected medicine entries: ${_parsedPreview.length}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              if (_parsedPreview.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    lowConfidenceCount == 0
                        ? 'Smart quality check: all entries look reliable.'
                        : 'Smart quality check: $lowConfidenceCount entr${lowConfidenceCount == 1 ? 'y' : 'ies'} need manual verification.',
                    style: TextStyle(
                      color: lowConfidenceCount == 0
                          ? Colors.green.shade700
                          : Colors.orange.shade800,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (_parsedPreview.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'No medicine schedule found yet. Add dose time terms like "8:00 PM", "1-0-1", "morning".',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              if (_parsedPreview.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    children: previewItems.map((med) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 2),
                              child: Icon(Icons.medication, size: 16),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${med['name']} ${med['dosage']} | Qty ${med['quantity'] ?? '-'} | ${med['durationText'] ?? '-'} | ${_displayTimeLabel(med)} | ${_entryConfidenceLabel(med)} (${_entryConfidenceScore(med)}%)',
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Not Correct'),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.pop(context, _controller.text.trim());
          },
          child: const Text('Correct, Save'),
        ),
      ],
    );
  }
}
