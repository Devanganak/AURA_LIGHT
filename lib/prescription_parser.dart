import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:flutter/material.dart';

class PrescriptionParser {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static Database? _database;
  static bool _tzInitialized = false;

  /// Initialize DB, notifications and timezone data.
  static Future<void> init() async {
    await _initDb();
    await _initNotifications();
    await _initTimeZone();
  }

  static Future<void> _initDb() async {
    final dbPath = await getDatabasesPath();
    _database = await openDatabase(
      join(dbPath, 'prescriptions.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE medicines(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            dosage TEXT,
            time_keyword TEXT,
            hour INTEGER,                 -- ⭐ ADDED
            minute INTEGER                -- ⭐ ADDED
          )
        ''');
      },
    );
  }

  static Future<void> _initNotifications() async {
    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    final DarwinInitializationSettings iosInit = DarwinInitializationSettings(
      requestSoundPermission: true,
      requestBadgePermission: true,
      requestAlertPermission: true,
    );

    final InitializationSettings initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );

    await _notificationsPlugin.initialize(initSettings);
  }

  static Future<void> _initTimeZone() async {
    if (_tzInitialized) return;
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation(tz.local.name));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));
    }
    _tzInitialized = true;
  }

  /// ⭐⭐ UPDATED PARSER: detects real times like "1:10 PM"
  static List<Map<String, String>> parsePrescriptionText(String text) {
    final List<Map<String, String>> result = [];
    final lines = text.split(RegExp(r'\r?\n'));

    final medicineRegex = RegExp(r'([A-Za-z][A-Za-z0-9\-\s]{1,50})');
    final dosageRegex = RegExp(
        r'(\d+\s*(?:mg|ml|mcg|g|units)|\d+/\d+|tablet|tabs|cap|caps)',
        caseSensitive: false);

    /// ⭐ NEW: detects 1:10 PM, 7pm, 01:30am
    final exactTimeRegex = RegExp(
      r'(\b\d{1,2}:\d{2}\s?(AM|PM|am|pm)\b|\b\d{1,2}\s?(AM|PM|am|pm)\b)',
    );

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      final medMatch = medicineRegex.firstMatch(line);
      final doseMatch = dosageRegex.firstMatch(line);
      final exactTimeMatch = exactTimeRegex.firstMatch(line);

      if (medMatch != null && doseMatch != null && exactTimeMatch != null) {
        final timeString = exactTimeMatch.group(0)!;
        final parsed = _parseTime(timeString); // ⭐ USE new parser

        result.add({
          'name': medMatch.group(0)!.trim(),
          'dosage': doseMatch.group(0)!.trim(),
          'hour': parsed['hour'].toString(),
          'minute': parsed['minute'].toString(),
          'time': timeString,
        });
      }
    }
    return result;
  }

  /// ⭐ NEW: converts "1:10 PM" → hour/minute
  static Map<String, int> _parseTime(String t) {
    t = t.toUpperCase().trim();

    final hm = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(t);
    int hour, minute;

    if (hm != null) {
      hour = int.parse(hm.group(1)!);
      minute = int.parse(hm.group(2)!);
    } else {
      hour = int.parse(RegExp(r'\d{1,2}').firstMatch(t)!.group(0)!);
      minute = 0;
    }

    final isPM = t.contains("PM");
    final isAM = t.contains("AM");

    if (isPM && hour != 12) hour += 12;
    if (isAM && hour == 12) hour = 0;

    return {'hour': hour, 'minute': minute};
  }

  /// Save parsed medicines to DB
  static Future<void> saveToDatabase(List<Map<String, String>> items) async {
    if (_database == null) return;
    final batch = _database!.batch();

    for (final item in items) {
      batch.insert('medicines', {
        'name': item['name'],
        'dosage': item['dosage'],
        'time_keyword': item['time'],
        'hour': int.parse(item['hour']!),     // ⭐ ADDED
        'minute': int.parse(item['minute']!), // ⭐ ADDED
      });
    }

    await batch.commit(noResult: true);
  }

  /// ⭐ UPDATED: schedule using exact hour/min
  static Future<void> scheduleReminders(List<Map<String, String>> items) async {
    if (!_tzInitialized) {
      await _initTimeZone();
    }

    for (int i = 0; i < items.length; i++) {
      final med = items[i];

      final hour = int.parse(med['hour']!);
      final minute = int.parse(med['minute']!);

      final scheduled = _nextInstance(hour, minute);

      final androidDetails = AndroidNotificationDetails(
        'med_channel_id',
        'Medicine Reminders',
        channelDescription: 'Reminders to take medicines',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
      );

      final iosDetails = DarwinNotificationDetails();

      await _notificationsPlugin.zonedSchedule(
        1000 + i,
        'Medicine Reminder',
        '${med['name']} — ${med['dosage']}',
        scheduled,
        NotificationDetails(android: androidDetails, iOS: iosDetails),
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.wallClockTime,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    }
  }

  /// ⭐ NEW helper
  static tz.TZDateTime _nextInstance(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var date = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (date.isBefore(now)) date = date.add(const Duration(days: 1));
    return date;
  }

  /// Fetch DB items
  static Future<List<Map<String, dynamic>>> fetchAllMedicines() async {
    if (_database == null) return [];
    return await _database!.query('medicines', orderBy: 'id DESC');
  }

  /// ⭐ DELETE REMINDER
  static Future<void> deleteReminder(int id, int notifId) async {
    await _notificationsPlugin.cancel(notifId); // cancel notification
    await _database!.delete('medicines', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> cancelAllReminders() async {
    await _notificationsPlugin.cancelAll();
  }
}
