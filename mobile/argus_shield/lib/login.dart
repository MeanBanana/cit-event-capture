import 'package:flutter/material.dart';
import 'register_citizen.dart';
import 'supabase_service.dart';
import 'saved_contact_details.dart';
import 'citizen/citizen_home.dart';
import 'admin_screens/admin_dashboard.dart';
import 'investigator_dashboard/investigator_dashboard.dart';
import 'theme/app_theme.dart';
import 'theme/argus_widgets.dart';
import 'app_settings.dart';
import 'loadingscreen.dart';
import 'reset_password.dart';

class LoginPage extends StatefulWidget{
  /// Tests pass a fake in here, the app just uses the real one.
  final SupabaseService? service;

  /// Tests pass a fake in here, the app uses the phone's storage.
  final SavedContactStore? savedContacts;

  const LoginPage({super.key, this.service, this.savedContacts});

  @override
  State<LoginPage>  createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>{
  final TextEditingController userNameController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  /// Make sure username and password are filled in. Empty fields go red with
  /// "... is required", same as registration.
  final _formKey = GlobalKey<FormState>();

  late final SupabaseService service = widget.service ?? SupabaseService();
  late final SavedContactStore savedContacts =
      widget.savedContacts ?? SavedContactStore();
  bool isLoading = false;

  /// Email/phone remembered from the last login on this phone. Empty until
  /// someone logs in here.
  SavedContact _saved = const SavedContact();

  @override
  void initState() {
    super.initState();
    _loadSavedContact();
  }

  @override
  void dispose() {
    userNameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  /// When the app opens, check the phone for saved details. If there's
  /// nothing, _saved stays empty until someone logs in.
  Future<void> _loadSavedContact() async {
    final saved = await savedContacts.load();
    if (mounted) setState(() => _saved = saved);
  }

  /// After a successful login, save or update the details. The caller doesn't
  /// await this, the next screen doesn't need it.
  void _rememberContact(Map<String, dynamic>? profile) {
    if (profile == null) return;
    savedContacts.save(
      email: profile['email'] as String?,
      phone: profile['phonenumber'] as String?,
    );
  }

  Future<void> _login() async {
    final ctx = context;

    // empty field: show "required" under it and stay here
    if (!_formKey.currentState!.validate()) return;

    // pushReplacement everywhere below, so the loading screen replaces the
    // login page and Back from a dashboard doesn't bring you back here

    setState(() => isLoading = true);

    final result = await service.loginUser(
      username: userNameController.text,
      password: passwordController.text,
    );

    if (!ctx.mounted) return;

    final success = result["success"] == true;
    final role = result["profile"]?["role"];
    String message = result["message"];
    Widget nextScreen = const LoginPage(); // if login fails we just come back here

    if (success) {
      _rememberContact(result["profile"] as Map<String, dynamic>?);
    }

    // Still on the temporary password someone else set, so they have to
    // pick their own before getting to any dashboard.
    if (success && result["mustChangePassword"] == true) {
      Navigator.pushReplacement(
        ctx,
        MaterialPageRoute(
          builder: (_) => LoadingScreen(
            resultMessage: "Please choose your own password",
            nextScreen: ResetPasswordPage(firstLogin: true, service: widget.service),
          ),
        ),
      );
      if (mounted) setState(() => isLoading = false);
      return;
    }

    // pick the dashboard for their role
    if (success) {
      switch (role) {
        case 'citizen':
          nextScreen = const CitizenHome();
        case 'admin':
          nextScreen = const AdminDashboard();
        case 'investigator':
          nextScreen = const InvestigatorDashboard();
        default:
          // Unknown role: sign out so the session doesn't stay open, and go
          // back to login.
          await service.logout();
          if (!ctx.mounted) return;
          message = "This account has no dashboard. Contact an administrator.";
      }
    }

    Navigator.pushReplacement(
      ctx,
      MaterialPageRoute(
        builder: (_) => LoadingScreen(
          resultMessage: message,
          nextScreen: nextScreen,
        ),
      ),
    );

    if (mounted) setState(() => isLoading = false);
  }

  /// Open the Forgot password overlay, pre-filled with the saved email (they
  /// can change it). Slides up and fades in.
  Future<void> _showForgotPassword() async {
    final email = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black.withValues(alpha: 0.6),
      transitionDuration: const Duration(milliseconds: 380),
      pageBuilder: (context, _, _) => _ForgotPasswordPanel(saved: _saved),
      // slide up from a bit below, fade in, and scale up slightly
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.12), end: Offset.zero)
                .animate(curved),
            child: ScaleTransition(
              scale: Tween(begin: 0.96, end: 1.0).animate(curved),
              child: child,
            ),
          ),
        );
      },
    );

    if (email == null || !mounted) return; // closed without resetting

    // Send the reset email. The link opens the app on ResetPasswordPage
    // (see main.dart and the reset password bit of supabase_service.dart).
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Sending reset link...')),
    );
    final result = await service.sendPasswordReset(email);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(result["message"] as String),
          backgroundColor:
              result["success"] == true ? null : AppColors.danger,
          duration: const Duration(seconds: 6),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    // Barely any top/bottom padding so the buttons sit right at the bottom.
    // Left/right is the usual 30.
    const padding = EdgeInsets.symmetric(horizontal: 30, vertical: 4);

    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) => Scaffold(
      appBar: const ArgusAppBar(),
      body: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          // scrollable so it still fits with the keyboard open
          padding: padding,
          child: ConstrainedBox(
            // At least screen height so spaceBetween can push the bottom group
            // down to the edge. On short screens or with the keyboard up it's
            // taller than that and just scrolls.
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight - padding.vertical,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Empty first child, so spaceBetween splits the free space
                // above and below the form and it ends up centred between the
                // header and the bottom buttons. With no free space (short
                // screen, keyboard up) it all just scrolls.
                const SizedBox.shrink(),

                // the form
                Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      // height 1.0 and no leading space, otherwise the 50px
                      // Courier font adds a big blank band above the letters
                      Text(
                        appSettings.t('login'),
                        style: AppText.pageTitle.copyWith(height: 1.0),
                        textHeightBehavior: const TextHeightBehavior(
                          applyHeightToFirstAscent: false,
                          applyHeightToLastDescent: false,
                        ),
                      ),

                      const SizedBox(height: AppSpacing.large),

                      FieldLabel(appSettings.t('username')),
                      TextFormField(
                        controller: userNameController,
                        decoration: const InputDecoration(),
                        textInputAction: TextInputAction.next,
                        validator: (value) =>
                            (value == null || value.trim().isEmpty)
                                ? appSettings.t('usernameRequired')
                                : null,
                      ),

                      const SizedBox(height: AppSpacing.large),

                      FieldLabel(appSettings.t('password')),
                      TextFormField(
                        controller: passwordController,
                        obscureText: true,
                        decoration: const InputDecoration(),
                        validator: (value) => (value == null || value.isEmpty)
                            ? appSettings.t('passwordRequired')
                            : null,
                      ),

                      const SizedBox(height: AppSpacing.small),

                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _showForgotPassword,
                          child: Text(appSettings.t('forgotPassword')),
                        ),
                      ),
                    ],
                  ),
                ),

                // bottom: register, login button, footer
                Column(
                  children: [
                    // keeps a gap between this and the form on short screens
                    const SizedBox(height: AppSpacing.medium),

                    TextButton(
                      onPressed: (){
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => const RegisterPage()),
                        );
                      },
                      child: Text(
                        appSettings.t('registerCitizen'),
                        style: TextStyle(
                          decoration: TextDecoration.underline,
                          decorationColor: AppColors.accent,
                          decorationThickness: 2,
                        ),
                      ),
                    ),

                    const SizedBox(height: AppSpacing.medium),

                    PrimaryButton(
                      label: appSettings.t('accessSystem'),
                      onPressed: isLoading ? null : _login,
                    ),

                    const SizedBox(height: 15),

                    const Text(
                      "Argus Shield . Secure Access . SAPS Authorised",
                      textAlign: TextAlign.center,
                      style: AppText.footer,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    );
  }

}

// --- Forgot password overlay (email only)

class _ForgotPasswordPanel extends StatefulWidget {
  final SavedContact saved;

  const _ForgotPasswordPanel({required this.saved});

  @override
  State<_ForgotPasswordPanel> createState() => _ForgotPasswordPanelState();
}

class _ForgotPasswordPanelState extends State<_ForgotPasswordPanel> {
  // pre-filled with the email saved on this phone, they can change it
  late final _emailController =
      TextEditingController(text: widget.saved.email ?? '');
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  /// Check the email and close the overlay, handing it back to LoginPage.
  void _reset() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(_emailController.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    // lift the panel above the keyboard when the field is focused
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final hasSavedEmail = widget.saved.email?.isNotEmpty ?? false;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + keyboard),
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Material(
                color: AppColors.header,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: const BorderSide(color: AppColors.accent, width: 1.5),
                ),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.lock_reset,
                                color: AppColors.accent, size: 26),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text('Reset password',
                                  style: AppText.cardTitle),
                            ),
                            IconButton(
                              tooltip: 'Close',
                              icon: const Icon(Icons.close,
                                  color: AppColors.textMuted),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          "Enter your account's email address and we'll send "
                          'you a link to reset your password.',
                          style: AppText.bodyMuted,
                        ),
                        const SizedBox(height: AppSpacing.medium),
                        const FieldLabel('Email address'),
                        TextFormField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          style: AppText.body,
                          decoration: const InputDecoration(
                            hintText: 'you@example.com',
                            prefixIcon: Icon(Icons.alternate_email,
                                color: AppColors.accent),
                          ),
                          validator: (value) {
                            final text = value?.trim() ?? '';
                            if (text.isEmpty) return 'Enter your email address';
                            if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                .hasMatch(text)) {
                              return 'Enter a valid email address.';
                            }
                            return null;
                          },
                          onFieldSubmitted: (_) => _reset(),
                        ),
                        if (hasSavedEmail) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Icon(Icons.smartphone,
                                  size: 14, color: AppColors.textHint),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Filled in from your last login on this phone.',
                                  style: AppText.bodyMuted.copyWith(
                                    fontSize: 12,
                                    color: AppColors.textHint,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: AppSpacing.medium),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton(
                            onPressed: _reset,
                            style: ElevatedButton.styleFrom(
                              textStyle:
                                  AppText.buttonSmall.copyWith(fontSize: 17),
                            ),
                            child: const Text('Reset Password'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
