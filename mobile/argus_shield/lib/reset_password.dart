import 'package:flutter/material.dart';
import 'supabase_service.dart';
import 'login.dart';
import 'loadingscreen.dart';
import 'theme/app_theme.dart';
import 'theme/argus_widgets.dart';

/// Opened by main.dart when the user taps the reset link in their email
/// (AuthChangeEvent.passwordRecovery). The link has already signed them in
/// for this one purpose, so all that is left is choosing a new password.
///
/// After saving, the user is signed out and sent back to the login page.
/// Cancelling (or pressing Back) also signs out, so the reset session does
/// not stay open on the phone.
class ResetPasswordPage extends StatefulWidget {
  /// Optional so tests can pass in a fake; the app uses the real service.
  final SupabaseService? service;

  const ResetPasswordPage({super.key, this.service});

  /// Same minimum as Supabase's default (Authentication > Providers > Email).
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

  /// Clears every screen (this page included) so Back cannot return here.
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
      // Back = cancel, so the reset session is always signed out.
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
                  "New Password",
                  textAlign: TextAlign.center,
                  style: AppText.pageTitle.copyWith(height: 1.0),
                  textHeightBehavior: const TextHeightBehavior(
                    applyHeightToFirstAscent: false,
                    applyHeightToLastDescent: false,
                  ),
                ),
                const SizedBox(height: AppSpacing.small),
                const Text(
                  "Choose a new password for your Argus Shield account.",
                  textAlign: TextAlign.center,
                  style: AppText.bodyMuted,
                ),

                const SizedBox(height: AppSpacing.large),

                const FieldLabel("New password"),
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

                const FieldLabel("Confirm new password"),
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
                  label: _saving ? "Saving..." : "Save Password",
                  onPressed: _saving ? null : _save,
                ),

                const SizedBox(height: AppSpacing.small),

                TextButton(
                  onPressed: _saving ? null : _cancel,
                  child: const Text("Cancel"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
