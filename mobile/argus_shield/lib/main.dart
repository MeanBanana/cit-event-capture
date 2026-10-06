import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login.dart';
import 'reset_password.dart';
import 'theme/app_theme.dart';
import 'theme/argus_widgets.dart';

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
      theme: buildArgusTheme(),
      // keeps every page above the phone's navigation buttons
      builder: keepAboveSystemBars,
      home: const LoginPage(),
    );
  }
}
