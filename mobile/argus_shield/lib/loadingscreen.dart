import 'package:flutter/material.dart';

class LoadingScreen extends StatefulWidget {
  final String resultMessage;   // message shown only here
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
    // Delay before redirecting
    Future.delayed(const Duration(seconds: 1), () {
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
      backgroundColor: Colors.blueGrey,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Show result message here
            Text(
              widget.resultMessage,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
              ),
            ),
            const SizedBox(height: 20),
            // Spinner below
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}