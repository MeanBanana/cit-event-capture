// sign_out_button.dart — the logout icon that sits next to the settings
// icon in the app bar (citizen, admin and investigator dashboards).
// Signs out of Supabase and goes back to the login page, clearing the
// navigation history so Back can't return to the signed-in screens.

import 'package:flutter/material.dart';
import 'package:argus_shield/app_settings.dart';
import 'package:argus_shield/login.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart' show errorText, showSnack;

class SignOutButton extends StatelessWidget {
  /// Optional so tests can pass in a fake; the app uses the real service.
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
