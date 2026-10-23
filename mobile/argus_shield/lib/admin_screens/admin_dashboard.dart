// The admin's main screen. Same setup as citizen/citizen_dashboard.dart: this
// file builds the Scaffold, header and tabs, and each tab's file just returns
// its body.

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

/// The Argus header plus the admin tabs.
class AdminDashboard extends StatelessWidget {
  const AdminDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    // length has to match both the Tabs and the TabBarView children, in the
    // same order. If you reorder them, fix the tab indexes at the top of
    // overview.dart too (the "see more" links use them).
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) {
        return DefaultTabController(
          length: 4,
          child: Scaffold(
            // same two-line header as the citizen pages, diamond marker for admin
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
              // Four tabs on a phone's width, so the labels are a little
              // smaller than default with narrow padding. _TabLabel shrinks a
              // word further only if it still won't fit (tiny phones, big
              // system text), so nothing ever gets cut off.
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
                  // _TabLabel shrinks "Investigators" a bit if it has to
                  Tab(child: _TabLabel(appSettings.t('investigators'))),
                  Tab(child: _TabLabel(appSettings.t('submissions'))),
                ],
              ),
            ),
            // each page is its own file and only returns its body
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

/// A tab label on one line, scaled down (never cut off) if space is tight.
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