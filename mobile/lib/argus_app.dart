// argus_app.dart — application setup and ownership of shared session data.

import 'package:flutter/material.dart';
import 'citizen_store.dart';
import 'citizen_dashboard.dart';

/// Owns the shared objects for one running instance of the app.
class ArgusApp extends StatefulWidget {
  const ArgusApp({super.key});

  @override
  State<ArgusApp> createState() => _ArgusAppState();
}

// State owns objects that must survive widget rebuilds.
class _ArgusAppState extends State<ArgusApp> {
  // Create one shared store so all tabs see the same session data.
  final CitizenStore _store = CitizenStore();

  @override
  void dispose() {
    // Release the notifier when this app widget leaves the widget tree.
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // MaterialApp supplies navigation, text direction, and Material behaviour.
    return MaterialApp(
      title: 'Argus Shield',
      debugShowCheckedModeBanner: false,
      // Pass the existing object; do not create a different store per tab.
      home: CitizenDashboard(store: _store),
    );
  }
}
