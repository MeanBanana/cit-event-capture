// citizen_dashboard.dart — holds navigation and creates the three subpage widgets.

import 'package:flutter/material.dart';
import 'citizen_store.dart';
import 'app_styles.dart';
import 'upload_page.dart';
import 'submissions_page.dart';
import 'profile_page.dart';

/// Displays the citizen header and the Upload, Submissions, and Profile tabs.
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
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: argusNavy,
        // Header and tab bar remain visible while a page scrolls.
        appBar: AppBar(
          backgroundColor: argusHeader,
          foregroundColor: Colors.white,
          elevation: 0,
          toolbarHeight: 88,
          title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.radio_button_unchecked, size: 15),
                  SizedBox(width: 7),
                  Text(
                    'Citizen',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8),
              Text(
                'Argus Shield',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(43),
            child: ColoredBox(
              color: argusGold,
              child: TabBar(
                labelColor: Colors.white,
                unselectedLabelColor: Color(0xFFE8DDBF),
                indicatorColor: Colors.white,
                indicatorWeight: 3,
                labelStyle: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
                tabs: [
                  Tab(height: 43, text: 'Upload'),
                  Tab(height: 43, text: 'Submissions'),
                  Tab(height: 43, text: 'Profile'),
                ],
              ),
            ),
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
  }
}
