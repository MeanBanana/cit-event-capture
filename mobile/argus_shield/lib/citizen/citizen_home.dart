// citizen_home.dart — where a citizen lands after logging in.

import 'package:flutter/material.dart';
import 'citizen_store.dart';
import 'citizen_dashboard.dart';

/// Owns the citizen's session store and shows the citizen dashboard.
///
/// The login page navigates here when the signed-in user's role is 'citizen'.
/// (ArgusApp does the same job but builds its own MaterialApp, so it cannot be
/// pushed as a route from the login page.)
class CitizenHome extends StatefulWidget {
  const CitizenHome({super.key});

  @override
  State<CitizenHome> createState() => _CitizenHomeState();
}

class _CitizenHomeState extends State<CitizenHome> {
  // One shared store so all tabs see the same session data.
  final CitizenStore _store = CitizenStore();

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CitizenDashboard(store: _store);
}
