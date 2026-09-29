import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macconnect_phone/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows Wi-Fi and cable on the connect screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MacConnectApp());
    expect(find.text('MacConnect'), findsOneWidget);
    expect(find.text('Wi-Fi'), findsOneWidget);
    expect(find.text('Cable'), findsOneWidget);
    expect(find.text('Use your Mac from this phone.'), findsOneWidget);

    await tester.tap(find.text('Cable'));
    await tester.pump();
    expect(find.text('USB tethering'), findsOneWidget);
    expect(find.text('Connect through USB debugging'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
