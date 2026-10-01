// profile_page.dart — contact form, validation, and session save feedback.

import 'package:flutter/material.dart';
import 'citizen_store.dart';
import '../theme/app_theme.dart';
import '../theme/argus_widgets.dart';

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
      padding: AppSpacing.page,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('My profile', style: AppText.sectionTitle),
            const SizedBox(height: AppSpacing.small),
            const Text(
              'Keep your contact information up to date so an authorised '
              'investigator can reach you if they need more information.',
              style: AppText.bodyMuted,
            ),
            const SizedBox(height: AppSpacing.large),
            const FieldLabel('Full name'),
            TextFormField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(hintText: 'Enter your full name'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter your full name'
                  : null,
            ),
            const SizedBox(height: AppSpacing.medium),
            const FieldLabel('Email address'),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration:
                  const InputDecoration(hintText: 'Enter your email address'),
              // Basic presence check only; a server must verify real email ownership.
              validator: (value) => value == null || !value.trim().contains('@')
                  ? 'Enter a valid email address'
                  : null,
            ),
            const SizedBox(height: AppSpacing.medium),
            const FieldLabel('Phone number'),
            TextFormField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration:
                  const InputDecoration(hintText: 'Enter your phone number'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter your phone number'
                  : null,
            ),
            const SizedBox(height: AppSpacing.large),
            Center(
              child: PrimaryButton(
                label: 'Save Changes',
                onPressed: _saveProfile,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
