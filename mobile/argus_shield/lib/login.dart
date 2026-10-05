import 'package:flutter/material.dart';
import 'register_citizen.dart';
import 'supabase_service.dart';
import 'citizen/citizen_home.dart';
import 'admin_screens/admin_dashboard.dart';
import 'theme/app_theme.dart';
import 'theme/argus_widgets.dart';
import 'loadingscreen.dart';
import 'citizen/argus_app.dart';

class LoginPage extends StatefulWidget{
  /// Optional so tests can pass in a fake; the app uses the real service.
  final SupabaseService? service;

  const LoginPage({super.key, this.service});

  @override
  State<LoginPage>  createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>{
  final TextEditingController userNameController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  late final SupabaseService service = widget.service ?? SupabaseService();
  bool isLoading = false;

  @override
  void dispose() {
    userNameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final ctx = context;

    // pushReplacement (not push) everywhere below: the loading screen takes the
    // login page's place, so Back from a dashboard does not return here.
    if (userNameController.text.trim().isEmpty || passwordController.text.isEmpty) {
      Navigator.pushReplacement(
        ctx,
        MaterialPageRoute(
          builder: (_) => LoadingScreen(
            resultMessage: "Enter your username and password",
            nextScreen: const LoginPage(),
          ),
        ),
      );
      return;
    }

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

    // Choose the dashboard for the signed-in user's role
    if (success) {
      switch (role) {
        case 'citizen':
          nextScreen = const CitizenHome();
        case 'admin':
          nextScreen = const AdminDashboard();
        default:
          // Investigator screens are not built yet. Sign out again so the
          // session does not stay open, and return to the login page.
          await service.logout();
          if (!ctx.mounted) return;
          message = "Investigator screens are not available yet.";
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const ArgusAppBar(),
      // Scrolls so the form still fits when the keyboard is open
      body: SingleChildScrollView(
        padding: AppSpacing.page,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Text("Login", style: AppText.pageTitle),

            const SizedBox(height: AppSpacing.large),

            const FieldLabel("Username"),
            TextField(
              controller: userNameController,
              decoration: const InputDecoration(),
            ),

            const SizedBox(height: AppSpacing.large),

            const FieldLabel("Password"),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(),
            ),

            const SizedBox(height: AppSpacing.small),

            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () {},         //Add functionality for the forgot password button
                child: const Text("Forgot password?"),
              ),
            ),

            const SizedBox(height: 60),

            TextButton(
              onPressed: (){
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const RegisterPage()),
                );
              },
              child: const Text(
                "Register as citizen",
                style: TextStyle(
                  decoration: TextDecoration.underline,
                  decorationColor: AppColors.accent,
                  decorationThickness: 2,
                ),
              ),
            ),

            const SizedBox(height: AppSpacing.medium),

            PrimaryButton(
              label: "Access System",
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
      ),
    );
  }

}
