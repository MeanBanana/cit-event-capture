// admin_dashboard.dart — holds navigation and creates the admin subpage widgets.
// Works exactly like citizen/citizen_dashboard.dart: this file builds the
// Scaffold, header and tabs; each page file only returns its body.

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/admin_screens/overview.dart';
import 'package:argus_shield/admin_screens/cases.dart';
import 'package:argus_shield/admin_screens/investigators.dart';
import 'package:argus_shield/admin_screens/submissions.dart';

/// Displays the Argus header and the admin tabs.
/// Colours and fonts come from the app theme (theme/app_theme.dart).
class AdminDashboard extends StatelessWidget {
  const AdminDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    // length must equal the number of Tabs AND the number of TabBarView
    // children, and both lists must be in the same order.
    // If you reorder tabs, update the tab indexes at the top of overview.dart
    // (used by its "see more" links).
    return const DefaultTabController(
      length: 4,
      child: Scaffold(
        // Same two-line header as the citizen pages, with a diamond for admin.
        appBar: RoleAppBar(
          roleLabel: 'System Administrator',
          marker: RoleMarker.diamond,
          bottom: TabBar(
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Cases'),
              Tab(text: 'Investigators'),
              Tab(text: 'Submissions'),
            ],
          ),
        ),
        // Each page lives in its own Dart file and returns only its body.
        body: TabBarView(
          children: [
            AdminOverview(),
            AdminCases(),
            Investigators(),
            AdminSubmissions(),
          ],
        ),
      ),
    );
  }
}
