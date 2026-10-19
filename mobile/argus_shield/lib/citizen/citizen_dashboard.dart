// citizen_dashboard.dart — holds navigation and creates the three subpage widgets.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/argus_widgets.dart';
import '../settings_screen.dart';
import '../app_settings.dart';
import '../sign_out_button.dart';
import 'citizen_store.dart';
import 'upload_page.dart';
import 'submissions_page.dart';
import 'profile_page.dart';

/// Displays the Argus header and the Upload, Submissions, and Profile tabs.
/// Colours and fonts come from the app theme (theme/app_theme.dart).
class CitizenDashboard extends StatelessWidget {
  // Constructor injection: the app provides the shared store to this screen.
  final CitizenStore store;

  const CitizenDashboard({
    super.key,
    required this.store,
  });

  @override
  Widget build(BuildContext context) {
    // Three tab labels correspond to three children in TabBarView.
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) {
        return DefaultTabController(
      length: 3,
      child: Scaffold(
        // Same header as the login and register pages, plus the role and tabs.
        appBar: ArgusAppBar(
          roleLabel: appSettings.t('citizenRole'),
          actions: [
            IconButton(
              tooltip: appSettings.t('settings'),
              icon: const Icon(Icons.settings),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const SettingsScreen(),
                  ),
                );
              },
            ),
            const SignOutButton(),
          ],
          // Tabs sit on the navy header, so the words stay white in both modes.
          bottom: TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: AppColors.accent,
            tabs: [
              Tab(text: appSettings.t('upload')),
              Tab(text: appSettings.t('submissions')),
              Tab(text: appSettings.t('profileTab')),
            ],
          ),
        ),
        // Each page lives in its own Dart file and receives the same store.
        body: TabBarView(
          children: [
            UploadPage(store: store),
            SubmissionsPage(store: store),
            ProfilePage(store: store),
          ],
        ),
      ),
    );
      },
    );
  }
}
