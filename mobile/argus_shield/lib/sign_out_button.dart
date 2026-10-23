// The logout icon next to Settings in the app bar on every dashboard. Signs
// out and goes back to login, clearing the navigation stack so Back can't
// return to a signed-in screen.

import 'package:flutter/material.dart';
import 'package:argus_shield/app_settings.dart';
import 'package:argus_shield/login.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart' show errorText, showSnack;

class SignOutButton extends StatelessWidget {
  /// Tests pass a fake in here, the app just uses the real one.
  final SupabaseService? service;

  const SignOutButton({super.key, this.service});

  Future<void> _signOut(BuildContext context) async {
    try {
      await (service ?? SupabaseService()).logout();
      if (!context.mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (_) => false,
      );
    } catch (error) {
      if (context.mounted) showSnack(context, errorText(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: appSettings.t('signOut'),
      onPressed: () => _signOut(context),
      icon: const Icon(Icons.logout),
    );
  }
}
