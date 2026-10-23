import 'package:flutter/material.dart';
import 'theme/app_theme.dart';

class LoadingScreen extends StatefulWidget {
  final String resultMessage;
  final Widget nextScreen;

  const LoadingScreen({
    super.key,
    required this.resultMessage,
    required this.nextScreen,
  });

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => widget.nextScreen),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: AppSpacing.page,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.resultMessage,
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(fontSize: 20),
              ),
              const SizedBox(height: AppSpacing.medium),

              const CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}
