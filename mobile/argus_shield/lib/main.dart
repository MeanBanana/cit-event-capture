import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login.dart';
import 'reset_password.dart';
import 'theme/app_theme.dart';
import 'theme/argus_widgets.dart';
import 'app_settings.dart';
import 'connection_status.dart';

// The app starts on the login page. After logging in, login.dart sends each
// user to their own dashboard: citizens to CitizenHome, admins to
// AdminDashboard. To test the admin screens, log in with an admin account
// (see database/README.md, "Creating an admin").

/// Lets code outside the widget tree (the auth listener below) open screens.
final navigatorKey = GlobalKey<NavigatorState>();

/// Lets the auth listener show messages without a BuildContext.
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://tnydrlxptqegzhbvwpcq.supabase.co',
    publishableKey: 'sb_publishable_qyDg3_F69Cy2rpoWDvR-7A_Z3AXR8h3',
  );
  // Shows a friendly message whenever there is no internet or the server is
  // not answering (connection_status.dart). Not awaited: the app opens
  // straight away and the message appears if the first check fails.
  connection.start();
  runApp(const RootApp());
}

class RootApp extends StatefulWidget {
  const RootApp({super.key});

  @override
  State<RootApp> createState() => _RootAppState();
}

class _RootAppState extends State<RootApp> {
  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    // Rebuild the app when language or theme changes.
    appSettings.addListener(() => setState(() {}));
    // Password reset: when the user taps the link in the reset email, the
    // phone opens this app (argusshield://reset-password). supabase_flutter
    // checks the link with Supabase and fires passwordRecovery; we then show
    // the "New Password" screen in place of whatever was open.
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen(
      (data) {
        if (data.event == AuthChangeEvent.passwordRecovery) {
          navigatorKey.currentState?.pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const ResetPasswordPage()),
            (_) => false,
          );
        }
      },
      // An old or already-used link ends up here instead.
      onError: (Object error) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text(
              'This reset link is invalid or has expired. '
              'Please request a new one.',
            ),
            backgroundColor: AppColors.danger,
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Argus Shield',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      // All colours, fonts and widget styles come from theme/app_theme.dart
      theme: buildArgusLightTheme(),
      darkTheme: buildArgusTheme(),
      themeMode: appSettings.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      // keeps every page above the phone's navigation buttons, with the
      // "No internet" / "Server not responding" strip at the top
      builder: (context, child) =>
          ConnectionBanner(child: keepAboveSystemBars(context, child)),
      home: const LoginPage(),
    );
  }
}