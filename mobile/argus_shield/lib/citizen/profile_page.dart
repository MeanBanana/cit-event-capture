// profile_page.dart — the logged-in citizen's details, loaded from Supabase.
//
// Full name is shown but cannot be changed. Email, phone number and
// residence are filled in with the current values; Save Changes sends only
// what was changed (see CitizenStore.saveProfile).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'citizen_store.dart';
import '../theme/app_theme.dart';
import '../theme/argus_widgets.dart';
import '../app_settings.dart';

/// Displays the citizen's profile and saves changes to Supabase.
class ProfilePage extends StatefulWidget {
  final CitizenStore store;

  const ProfilePage({super.key, required this.store});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage>
    with AutomaticKeepAliveClientMixin<ProfilePage> {
  // The form key triggers validation; controllers hold the field values.
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController(); // read-only
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _residenceController = TextEditingController();

  /// The profile the fields were last filled from. When the store's profile
  /// becomes a different object (first load, a save, a reload), the fields
  /// are refilled from it.
  CitizenProfile? _filledFrom;
  bool _saving = false;

  @override
  // Retain form input while another tab is visible.
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_fillFromStore);
    _fillFromStore();

    // CitizenHome normally starts the load at login. This covers the case
    // where it hasn't (and no error is showing yet). Run after the first
    // frame, because loading notifies listeners and that can't happen
    // while widgets are still being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final store = widget.store;
      if (mounted &&
          store.profile == null &&
          !store.profileLoading &&
          store.profileError == null) {
        store.loadProfile();
      }
    });
  }

  @override
  void dispose() {
    widget.store.removeListener(_fillFromStore);
    // Clean up text controllers when the page leaves the widget tree.
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _residenceController.dispose();
    super.dispose();
  }

  /// Copies the store's profile into the fields when it's new.
  void _fillFromStore() {
    final profile = widget.store.profile;
    if (profile == null || identical(profile, _filledFrom)) return;
    _filledFrom = profile;
    _nameController.text = profile.fullName;
    _emailController.text = profile.email;
    _phoneController.text = profile.localPhone;
    _residenceController.text = profile.residence ?? '';
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus(); // close the keyboard

    setState(() => _saving = true);
    Map<String, dynamic> result;
    try {
      result = await widget.store.saveProfile(
        email: _emailController.text,
        phone: _phoneController.text,
        residence: _residenceController.text,
      );
    } on ArgumentError catch (e) {
      result = {"success": false, "message": e.message.toString()};
    }
    if (!mounted) return;
    setState(() => _saving = false);

    // A requested email change only applies once confirmed, so show the
    // current (confirmed) address again instead of the typed one.
    if (result["emailPending"] == true) {
      _emailController.text = widget.store.profile?.email ?? '';
    }

    final success = result["success"] == true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result["message"] as String? ?? ''),
        backgroundColor: success ? null : AppColors.danger,
        duration: Duration(seconds: result["emailPending"] == true ? 6 : 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keeps this page alive during tab changes.
    super.build(context);
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final store = widget.store;
        return SingleChildScrollView(
          padding: AppSpacing.page,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(appSettings.t('myProfile'), style: titleOnPage(context)),
              const SizedBox(height: AppSpacing.small),
              Text(
                appSettings.t('profileIntro'),
                style: mutedOnPage(context),
              ),
              const SizedBox(height: AppSpacing.large),
              if (store.profile != null)
                _buildForm(store.profile!)
              else if (store.profileError != null)
                _buildError(store.profileError!)
              else
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.large),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildError(String message) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message, style: AppText.body.copyWith(color: AppColors.danger)),
        const SizedBox(height: AppSpacing.small),
        TextButton.icon(
          onPressed: widget.store.loadProfile,
          icon: const Icon(Icons.refresh),
          label: Text(appSettings.t('tryAgain')),
        ),
      ],
    );
  }

  Widget _buildForm(CitizenProfile profile) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FieldLabel(appSettings.t('fullName')),
          // Read-only: names are fixed after registration.
          TextFormField(
            controller: _nameController,
            readOnly: true,
            enableInteractiveSelection: false,
            style: AppText.body.copyWith(color: pageInkMuted(context)),
            decoration: InputDecoration(
              suffixIcon: Icon(Icons.lock_outline, color: pageInkMuted(context)),
              helperText: appSettings.t('nameLocked'),
              helperStyle: TextStyle(color: pageInkMuted(context)),
            ),
          ),
          const SizedBox(height: 4),
          Text('${appSettings.t('username')}: ${profile.username}', style: mutedOnPage(context)),
          const SizedBox(height: AppSpacing.medium),

          FieldLabel(appSettings.t('emailAddress')),
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration:
                InputDecoration(hintText: appSettings.t('enterEmail')),
            // Same check as the register form.
            validator: (value) {
              final text = value?.trim() ?? '';
              if (text.isEmpty) return appSettings.t('emailRequired');
              if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(text)) {
                return appSettings.t('validEmail');
              }
              return null;
            },
          ),
          const SizedBox(height: AppSpacing.medium),

          FieldLabel(appSettings.t('phoneNumber')),
          TextFormField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            // Same format as the register form: "+27 " shown, 9 digits typed.
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(9),
            ],
            decoration: const InputDecoration(prefixText: '+27 '),
            validator: (value) {
              if (value == null || value.isEmpty) return appSettings.t('phoneRequired');
              if (value.length != 9) {
                return appSettings.t('phoneLength');
              }
              return null;
            },
          ),
          const SizedBox(height: AppSpacing.medium),

          FieldLabel(appSettings.t('residence')),
          TextFormField(
            controller: _residenceController,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(hintText: appSettings.t('residenceHint')),
            validator: (value) => value == null || value.trim().isEmpty
                ? appSettings.t('residenceRequired')
                : null,
          ),
          const SizedBox(height: AppSpacing.large),

          Center(
            child: PrimaryButton(
              label: _saving ? appSettings.t('saving') : appSettings.t('saveChanges'),
              onPressed: _saving ? null : _saveProfile,
            ),
          ),
        ],
      ),
    );
  }
}
