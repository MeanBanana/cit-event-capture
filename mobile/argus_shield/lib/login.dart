import 'package:flutter/material.dart';
import 'register_citizen.dart';
import 'supabase_service.dart';
import 'citizen/citizen_home.dart';
import 'theme/app_theme.dart';
import 'theme/argus_widgets.dart';

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
    if (userNameController.text.trim().isEmpty || passwordController.text.isEmpty) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(content: Text('Enter your username and password')),
      );
      return;
    }

    setState(() => isLoading = true);
    final result = await service.loginUser(
      username: userNameController.text,
      password: passwordController.text,
    );
    if (!ctx.mounted) return;
    setState(() => isLoading = false);

    if (result["success"] == true) {
      // "User".role in the database: 'citizen' | 'investigator' | 'admin'
      final role = result["profile"]["role"];

      if (role == 'citizen') {
        // Look this up before navigating: the login page is about to go away.
        final messenger = ScaffoldMessenger.of(ctx);
        // pushReplacement so the back button does not return to the login form
        Navigator.of(ctx).pushReplacement(
          MaterialPageRoute(builder: (_) => const CitizenHome()),
        );
        messenger.showSnackBar(
          SnackBar(
            content: Text(result["message"]),
            backgroundColor: AppColors.success,
          ),
        );
        return;
      }

      // TODO: open the investigator / admin dashboards once they are wired up.
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text("${result["message"]} (logged in as $role)"),
          backgroundColor: AppColors.success,
        ),
      );
    } else {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(result["message"]),
          backgroundColor: AppColors.danger,
        ),
      );
    }
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
