import 'package:flutter/material.dart';
import 'supabase_service.dart';
import 'login.dart';
import 'loadingscreen.dart';
import 'theme/app_theme.dart';
import 'theme/argus_widgets.dart';
import 'app_settings.dart';

/// Choose a new password.
///
/// main.dart opens this when someone taps the reset link in their email
/// (AuthChangeEvent.passwordRecovery). The link has already signed them in
/// for just this, so all that's left is picking the password.
///
/// login.dart also opens it with [firstLogin] when a new admin or
/// investigator signs in with their temporary password, since they have to
/// pick their own before using the app.
///
/// Saving signs them out and sends them back to login. Cancelling or Back
/// signs out too, so the reset session never stays open on the phone.
class ResetPasswordPage extends StatefulWidget {
  /// Tests pass a fake in here, the app just uses the real one.
  final SupabaseService? service;

  /// True on first login with a temporary password (changes the title).
  final bool firstLogin;

  const ResetPasswordPage({super.key, this.service, this.firstLogin = false});

  /// Matches Supabase's default (Authentication > Providers > Email).
  static const minLength = 6;

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  late final SupabaseService service = widget.service ?? SupabaseService();

  bool _saving = false;
  bool _showPassword = false;
  String? _error; // from Supabase, shown above the button

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    final result = await service.updatePassword(_passwordController.text);
    if (!mounted) return;

    if (result["success"] != true) {
      setState(() {
        _saving = false;
        _error = result["message"] as String?;
      });
      return;
    }

    await service.logout();
    if (!mounted) return;
    _goToLogin(result["message"] as String);
  }

  Future<void> _cancel() async {
    if (_saving) return;
    setState(() => _saving = true);
    await service.logout();
    if (!mounted) return;
    _goToLogin("Password not changed");
  }

  /// Clear every screen including this one, so Back can't come back here.
  void _goToLogin(String message) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => LoadingScreen(
          resultMessage: message,
          nextScreen: const LoginPage(),
        ),
      ),
      (_) => false,
    );
  }

  String? _validatePassword(String? value) {
    final text = value ?? '';
    if (text.isEmpty) return 'Enter a new password';
    if (text.length < ResetPasswordPage.minLength) {
      return 'Use at least ${ResetPasswordPage.minLength} characters';
    }
    return null;
  }

  String? _validateConfirm(String? value) {
    if ((value ?? '').isEmpty) return 'Type the new password again';
    if (value != _passwordController.text) return 'Passwords do not match';
    return null;
  }

  Widget _visibilityToggle() => IconButton(
        tooltip: _showPassword ? 'Hide password' : 'Show password',
        icon: Icon(
          _showPassword ? Icons.visibility_off : Icons.visibility,
          color: AppColors.textMuted,
        ),
        onPressed: () => setState(() => _showPassword = !_showPassword),
      );

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back means cancel, which always signs the reset session out
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        appBar: const ArgusAppBar(),
        body: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 4),
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                Text(
                  appSettings.t(widget.firstLogin ? 'choosePassword' : 'newPassword'),
                  textAlign: TextAlign.center,
                  style: AppText.pageTitle.copyWith(height: 1.0),
                  textHeightBehavior: const TextHeightBehavior(
                    applyHeightToFirstAscent: false,
                    applyHeightToLastDescent: false,
                  ),
                ),
                const SizedBox(height: AppSpacing.small),
                Text(
                  appSettings.t(
                      widget.firstLogin ? 'choosePasswordBody' : 'newPasswordBody'),
                  textAlign: TextAlign.center,
                  style: mutedOnPage(context),
                ),

                const SizedBox(height: AppSpacing.large),

                FieldLabel(appSettings.t('newPasswordLabel')),
                TextFormField(
                  controller: _passwordController,
                  obscureText: !_showPassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: AppText.body,
                  decoration: InputDecoration(suffixIcon: _visibilityToggle()),
                  validator: _validatePassword,
                  textInputAction: TextInputAction.next,
                ),

                const SizedBox(height: AppSpacing.large),

                FieldLabel(appSettings.t('confirmNewPassword')),
                TextFormField(
                  controller: _confirmController,
                  obscureText: !_showPassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: AppText.body,
                  decoration: InputDecoration(suffixIcon: _visibilityToggle()),
                  validator: _validateConfirm,
                  onFieldSubmitted: (_) => _save(),
                ),

                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.medium),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: AppText.body.copyWith(color: AppColors.danger),
                  ),
                ],

                const SizedBox(height: AppSpacing.large),

                PrimaryButton(
                  label: _saving ? appSettings.t('saving') : appSettings.t('savePassword'),
                  onPressed: _saving ? null : _save,
                ),

                const SizedBox(height: AppSpacing.small),

                TextButton(
                  onPressed: _saving ? null : _cancel,
                  child: Text(appSettings.t('cancel')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
