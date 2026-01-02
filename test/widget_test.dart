// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auralight/main.dart'; // ✅ Make sure this matches your project name in pubspec.yaml

void main() {
  testWidgets('BillReaderApp loads correctly', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(BillReaderApp()); // ✅ Changed from MyApp() to BillReaderApp()

    // Verify that the app bar title "Bill Reader" is shown.
    expect(find.text('Bill Reader'), findsOneWidget);

    // Verify that the text instructing user is shown.
    expect(find.textContaining('Upload a bill'), findsOneWidget);
  });
}

