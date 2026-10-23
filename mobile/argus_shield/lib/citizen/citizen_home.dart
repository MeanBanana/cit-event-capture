// Where a citizen lands after logging in.

import 'package:flutter/material.dart';
import '../supabase_service.dart';
import 'citizen_store.dart';
import 'citizen_dashboard.dart';

// Holds the citizen's store and shows their dashboard. login.dart sends
// citizens here.
class CitizenHome extends StatefulWidget {
  // tests pass a fake in here, the app just uses the real one
  final SupabaseService? service;

  const CitizenHome({super.key, this.service});

  @override
  State<CitizenHome> createState() => _CitizenHomeState();
}

class _CitizenHomeState extends State<CitizenHome> {
  // one store shared by all the tabs
  late final CitizenStore _store = CitizenStore(service: widget.service);

  @override
  void initState() {
    super.initState();
    // Start loading the profile right after login so it's usually ready by
    // the time they open the Profile tab
    _store.loadProfile();
    // and their reports for the Submissions tab
    _store.loadSubmissions();
  }

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CitizenDashboard(store: _store);
}
