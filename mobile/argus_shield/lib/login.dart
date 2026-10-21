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
  /// Optional so tests can pass in a fake; the app uses the real service.
  final SupabaseService? service;

  /// Optional so tests can pass in a fake; the app uses the device storage.
  final SavedContactStore? savedContacts;

  const LoginPage({super.key, this.service, this.savedContacts});

  @override
  State<LoginPage>  createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>{
  final TextEditingController userNameController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  /// Checks that username and password are filled in before logging in;
  /// an empty field turns red with "... is required" (like registration).
  final _formKey = GlobalKey<FormState>();

  late final SupabaseService service = widget.service ?? SupabaseService();
  late final SavedContactStore savedContacts =
      widget.savedContacts ?? SavedContactStore();
  bool isLoading = false;

  /// Email/phone remembered on this phone from the last login. Empty until
  /// someone has logged in on this device.
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

  /// Step 1 of the saved-details flow: when the app opens, check the device.
  /// If nothing is there yet, _saved stays empty until the user logs in.
  Future<void> _loadSavedContact() async {
    final saved = await savedContacts.load();
    if (mounted) setState(() => _saved = saved);
  }

  /// Step 2: after a successful login, insert or update the saved details.
  /// Not awaited by the caller - the next screen doesn't need to wait for it.
  void _rememberContact(Map<String, dynamic>? profile) {
    if (profile == null) return;
    savedContacts.save(
      email: profile['email'] as String?,
      phone: profile['phonenumber'] as String?,
    );
  }

  Future<void> _login() async {
    final ctx = context;

    // An empty field: show "required" under it and stay on this page.
    if (!_formKey.currentState!.validate()) return;

    // pushReplacement (not push) everywhere below: the loading screen takes the
    // login page's place, so Back from a dashboard does not return here.

    setState(() => isLoading = true);

    final result = await service.loginUser(
      username: userNameController.text,
      password: passwordController.text,
    );

    if (!ctx.mounted) return;

    final success = result["success"] == true;
    final role = result["profile"]?["role"];
    String message = result["message"];
    Widget nextScreen = const LoginPage(); // failed login: back to this page

    if (success) {
      _rememberContact(result["profile"] as Map<String, dynamic>?);
    }

    // Still on the temporary password from whoever made the account: they
    // must choose their own before reaching any dashboard.
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

    // Choose the dashboard for the signed-in user's role
    if (success) {
      switch (role) {
        case 'citizen':
          nextScreen = const CitizenHome();
        case 'admin':
          nextScreen = const AdminDashboard();
        case 'investigator':
          nextScreen = const InvestigatorDashboard();
        default:
          // Unknown role: sign out again so the session does not stay
          // open, and return to the login page.
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

  /// Opens the Forgot password overlay, pre-filled with the email saved on
  /// this phone (editable). It slides up and fades in as it opens.
  Future<void> _showForgotPassword() async {
    final email = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black.withValues(alpha: 0.6),
      transitionDuration: const Duration(milliseconds: 380),
      pageBuilder: (context, _, _) => _ForgotPasswordPanel(saved: _saved),
      // Slide up from slightly below + fade + a touch of scale.
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

    // Emails the reset link. Tapping it opens the app on ResetPasswordPage
    // (see main.dart and supabase_service.dart, "RESET PASSWORD").
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
    // Tiny top/bottom padding so the buttons sit right at the bottom.
    // Left/right stay at the usual 30.
    const padding = EdgeInsets.symmetric(horizontal: 30, vertical: 4);

    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) => Scaffold(
      appBar: const ArgusAppBar(),
      body: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          // Scrolls so the form still fits when the keyboard is open
          padding: padding,
          child: ConstrainedBox(
            // At least as tall as the screen, so spaceBetween below can push
            // the bottom group down to the bottom edge. On a short screen
            // (or with the keyboard open) the content is taller and scrolls.
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight - padding.vertical,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Empty first child: with spaceBetween, the free space is
                // split equally above and below the form, so the form sits
                // centred between the header and the bottom buttons. On a
                // short screen (or with the keyboard open) there is no free
                // space and everything simply scrolls.
                const SizedBox.shrink(),

                // ---- middle: the form
                Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      // height 1.0 + no extra space above the first line:
                      // the 50px Courier font otherwise adds a tall blank band
                      // above the letters.
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

                // ---- bottom: register, login button, footer
                Column(
                  children: [
                    // keeps a gap from the form on short screens
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

// ===========================================================================
// Forgot password overlay (email only)
// ===========================================================================

class _ForgotPasswordPanel extends StatefulWidget {
  final SavedContact saved;

  const _ForgotPasswordPanel({required this.saved});

  @override
  State<_ForgotPasswordPanel> createState() => _ForgotPasswordPanelState();
}

class _ForgotPasswordPanelState extends State<_ForgotPasswordPanel> {
  // Pre-filled with the email saved on this phone; the user can change it.
  late final _emailController =
      TextEditingController(text: widget.saved.email ?? '');
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  /// Checks the email and closes the overlay, returning it to LoginPage.
  void _reset() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(_emailController.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    // Lift the panel above the keyboard when the field is focused.
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
