// argus_app.dart — runs the citizen screens on their own (without logging in),
// handy for working on the citizen UI. The real app starts at main.dart.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/argus_widgets.dart';
import 'citizen_home.dart';

class ArgusApp extends StatelessWidget {
  const ArgusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Argus Shield',
      debugShowCheckedModeBanner: false,
      theme: buildArgusTheme(),
      // keeps every page above the phone's navigation buttons
      builder: keepAboveSystemBars,
      // CitizenHome owns the shared CitizenStore for the three tabs.
      home: const CitizenHome(),
    );
  }
}
