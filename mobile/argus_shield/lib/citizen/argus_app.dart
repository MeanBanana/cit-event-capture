// Runs the citizen screens on their own without logging in, handy when
// working on the citizen UI. The real entry point is main.dart.

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
      // keeps pages above the phone's nav buttons
      builder: keepAboveSystemBars,
      // CitizenHome owns the CitizenStore the three tabs share
      home: const CitizenHome(),
    );
  }
}
