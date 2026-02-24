import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const String _textScaleKey = 'app_text_scale_v1';
  static const double minTextScale = 0.9;
  static const double maxTextScale = 1.6;
  static const double defaultTextScale = 1.0;

  static final ValueNotifier<double> textScale =
      ValueNotifier<double>(defaultTextScale);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedScale = prefs.getDouble(_textScaleKey);
    textScale.value = _clampScale(savedScale ?? defaultTextScale);
  }

  static void setTextScale(double value) {
    textScale.value = _clampScale(value);
  }

  static Future<void> persistTextScale(double value) async {
    final clamped = _clampScale(value);
    textScale.value = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_textScaleKey, clamped);
  }

  static double _clampScale(double value) {
    return value.clamp(minTextScale, maxTextScale).toDouble();
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late double _sliderScale;

  @override
  void initState() {
    super.initState();
    _sliderScale = AppSettings.textScale.value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Text Size',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Adjust reading size for the entire app.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  ValueListenableBuilder<double>(
                    valueListenable: AppSettings.textScale,
                    builder: (context, value, _) {
                      return Text(
                        'Current: ${(value * 100).round()}%',
                        style: theme.textTheme.titleMedium,
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Slider(
                    value: _sliderScale,
                    min: AppSettings.minTextScale,
                    max: AppSettings.maxTextScale,
                    divisions: 14,
                    label: '${(_sliderScale * 100).round()}%',
                    onChanged: (value) {
                      setState(() => _sliderScale = value);
                      AppSettings.setTextScale(value);
                    },
                    onChangeEnd: (value) async {
                      await AppSettings.persistTextScale(value);
                    },
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton(
                        onPressed: () {
                          setState(
                            () => _sliderScale = AppSettings.defaultTextScale,
                          );
                          AppSettings.persistTextScale(
                            AppSettings.defaultTextScale,
                          );
                        },
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ValueListenableBuilder<double>(
                valueListenable: AppSettings.textScale,
                builder: (context, value, _) {
                  return Text(
                    'Preview text. Use this slider until this sentence is easy to read on your screen.',
                    style: theme.textTheme.bodyLarge,
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
