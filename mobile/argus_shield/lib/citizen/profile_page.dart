// profile_page.dart — contact form, validation, and session save feedback.

import 'package:flutter/material.dart';
import 'citizen_store.dart';
import 'app_styles.dart';

/// Displays editable contact details and saves them to the session store.
class ProfilePage extends StatefulWidget {
  final CitizenStore store;

  const ProfilePage({super.key, required this.store});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage>
    with AutomaticKeepAliveClientMixin<ProfilePage> {
  // The form key triggers validation; controllers hold editable field values.
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();

  @override
  // Retain form input while another tab is visible.
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Populate the form from a previously saved profile, if one exists.
    final profile = widget.store.profile;
    if (profile != null) {
      _nameController.text = profile.name;
      _emailController.text = profile.email;
      _phoneController.text = profile.phone;
    }
  }

  @override
  void dispose() {
    // Clean up text controllers when the page leaves the widget tree.
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  /// Saves valid contact fields; this does not update an authentication account.
  void _saveProfile() {
    if (!_formKey.currentState!.validate()) return;
    // The store trims values, validates again, and replaces the saved profile.
    widget.store.saveProfile(
      name: _nameController.text,
      email: _emailController.text,
      phone: _phoneController.text,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Profile saved for this app session.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keeps this page alive during tab changes.
    super.build(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 25, 22, 35),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'MY PROFILE',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Keep your contact information up to date so an authorised '
              'investigator can reach you if they need more information.',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 15,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 26),
            const FormLabel('FULL NAME'),
            const SizedBox(height: 5),
            TextFormField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              textCapitalization: TextCapitalization.words,
              decoration: fieldDecoration('Enter your full name'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter your full name'
                  : null,
            ),
            const SizedBox(height: 18),
            const FormLabel('EMAIL ADDRESS'),
            const SizedBox(height: 5),
            TextFormField(
              controller: _emailController,
              style: const TextStyle(color: Colors.white),
              keyboardType: TextInputType.emailAddress,
              decoration: fieldDecoration('Enter your email address'),
              // Basic presence check only; a server must verify real email ownership.
              validator: (value) => value == null || !value.trim().contains('@')
                  ? 'Enter a valid email address'
                  : null,
            ),
            const SizedBox(height: 18),
            const FormLabel('PHONE NUMBER'),
            const SizedBox(height: 5),
            TextFormField(
              controller: _phoneController,
              style: const TextStyle(color: Colors.white),
              keyboardType: TextInputType.phone,
              decoration: fieldDecoration('Enter your phone number'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter your phone number'
                  : null,
            ),
            const SizedBox(height: 28),
            Center(
              child: SizedBox(
                width: 245,
                height: 47,
                child: ElevatedButton(
                  onPressed: _saveProfile,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: argusGold,
                    foregroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(),
                  ),
                  child: const Text(
                    'SAVE CHANGES',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
