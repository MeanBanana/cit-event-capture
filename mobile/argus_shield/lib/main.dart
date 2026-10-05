import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login.dart';
import 'theme/app_theme.dart';
import 'theme/argus_widgets.dart';

// The app starts on the login page. After logging in, login.dart sends each
// user to their own dashboard: citizens to CitizenHome, admins to
// AdminDashboard. To test the admin screens, log in with an admin account
// (see database/README.md, "Creating an admin").

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://tnydrlxptqegzhbvwpcq.supabase.co',
    publishableKey: 'sb_publishable_qyDg3_F69Cy2rpoWDvR-7A_Z3AXR8h3',
  );
  runApp(const RootApp());
}

class RootApp extends StatelessWidget {
  const RootApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Argus Shield',
      debugShowCheckedModeBanner: false,
      // All colours, fonts and widget styles come from theme/app_theme.dart
      theme: buildArgusTheme(),
      // keeps every page above the phone's navigation buttons
      builder: keepAboveSystemBars,
      home: const LoginPage(),
    );
  }
}
