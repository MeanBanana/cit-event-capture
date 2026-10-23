import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login.dart';
import 'reset_password.dart';
import 'theme/app_theme.dart';
import 'theme/argus_widgets.dart';
import 'app_settings.dart';
import 'connection_status.dart';

// Everyone starts on the login page, and login.dart sends them on to their
// own dashboard (CitizenHome or AdminDashboard). To poke at the admin screens
// you need an admin account, see "Creating an admin" in database/README.md.

/// So code outside the widget tree (the auth listener below) can open screens.
final navigatorKey = GlobalKey<NavigatorState>();

/// So the auth listener can show messages without a BuildContext.
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://tnydrlxptqegzhbvwpcq.supabase.co',
    publishableKey: 'sb_publishable_qyDg3_F69Cy2rpoWDvR-7A_Z3AXR8h3',
  );
  // Warns when there's no internet or the server isn't answering
  // (connection_status.dart). Not awaited, the app opens straight away and
  // the warning just appears if the first check fails.
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
    // rebuild when the language or theme changes
    appSettings.addListener(() => setState(() {}));
    // Password reset: tapping the link in the email opens the app via
    // argusshield://reset-password. supabase_flutter checks it with Supabase
    // and fires passwordRecovery, and we swap in the "New Password" screen
    // over whatever was open.
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen(
      (data) {
        if (data.event == AuthChangeEvent.passwordRecovery) {
          navigatorKey.currentState?.pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const ResetPasswordPage()),
            (_) => false,
          );
        }
      },
      // old or already-used links end up here
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
      // colours, fonts and widget styles all live in theme/app_theme.dart
      theme: buildArgusLightTheme(),
      darkTheme: buildArgusTheme(),
      themeMode: appSettings.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      // keeps pages above the phone's nav buttons, and puts the "No internet"
      // / "Server not responding" strip at the top
      builder: (context, child) =>
          ConnectionBanner(child: keepAboveSystemBars(context, child)),
      home: const LoginPage(),
    );
  }
}