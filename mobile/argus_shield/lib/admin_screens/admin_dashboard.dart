// admin_dashboard.dart — holds navigation and creates the admin subpage widgets.
// Works exactly like citizen/citizen_dashboard.dart: this file builds the
// Scaffold, header and tabs; each page file only returns its body.

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/admin_screens/overview.dart';
import 'package:argus_shield/admin_screens/cases.dart';
import 'package:argus_shield/admin_screens/investigators.dart';
import 'package:argus_shield/admin_screens/submissions.dart';
import 'package:argus_shield/settings_screen.dart';
import 'package:argus_shield/app_settings.dart';
import 'package:argus_shield/sign_out_button.dart';

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
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) {
        return DefaultTabController(
          length: 4,
          child: Scaffold(
            // Same two-line header as the citizen pages, with a diamond for admin.
            appBar: RoleAppBar(
              roleLabel: appSettings.t('systemAdministrator'),
              marker: RoleMarker.diamond,
              actions: [
                IconButton(
                  tooltip: appSettings.t('settings'),
                  icon: const Icon(Icons.settings),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const SettingsScreen()),
                    );
                  },
                ),
                const SignOutButton(),
              ],
              // Four tabs share a phone's width, so the labels are a little
              // smaller than the app default and the padding around them is
              // narrow. _TabLabel shrinks a word further only if it still
              // wouldn't fit (very small phones, large system text), so no
              // label is ever cut off.
              bottom: TabBar(
                labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                labelStyle: const TextStyle(
                  fontFamily: AppFonts.body,
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontFamily: AppFonts.body,
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                ),
                tabs: [
                  Tab(child: _TabLabel(appSettings.t('overview'))),
                  Tab(child: _TabLabel(appSettings.t('cases'))),
                  // _TabLabel shrinks "Investigators" slightly if needed.
                  Tab(child: _TabLabel(appSettings.t('investigators'))),
                  Tab(child: _TabLabel(appSettings.t('submissions'))),
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
      },
    );
  }
}

/// A tab's word on one line, scaled down (never cut off) when space is short.
class _TabLabel extends StatelessWidget {
  final String text;

  const _TabLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(text, maxLines: 1, softWrap: false),
    );
  }
}