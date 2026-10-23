// The citizen's main screen: header plus the Upload, Submissions and Profile tabs.

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

/// Argus header with the Upload, Submissions and Profile tabs.
class CitizenDashboard extends StatelessWidget {
  final CitizenStore store;

  const CitizenDashboard({
    super.key,
    required this.store,
  });

  @override
  Widget build(BuildContext context) {
    // the three tabs here have to line up with the three TabBarView children
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) {
        return DefaultTabController(
      length: 3,
      child: Scaffold(
        // same header as login/register, plus the role and the tabs
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
          // tabs sit on the navy header, so keep the labels white in both modes
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
        // each page is its own file and gets the same store
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
