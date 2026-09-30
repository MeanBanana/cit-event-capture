import 'package:supabase_flutter/supabase_flutter.dart';

/// All Supabase calls for accounts (register, login, logout).
///
/// How accounts work (see database/README.md):
///  * Registering calls supabase.auth.signUp with the form fields in `data`.
///    A database trigger then creates the "User" row and the "citizen" row.
///    The app must NEVER insert into "User" or "citizen" itself - the database
///    blocks it, so nobody can give themselves a role such as admin.
///  * Logging in: the user types a username, we look up their email with
///    email_for_username, then sign in with email + password.
class SupabaseService {
  // A getter (not a field) so this class can be created before Supabase is
  // initialised, e.g. in widget tests.
  SupabaseClient get supabase => Supabase.instance.client;

  // ---------------------------------------------------------------- REGISTER
  Future<Map<String, dynamic>> registerUser({
    required String firstname,
    required String surname,
    required String username,
    required String email,
    required String phone,
    required String residence,
    required String password,
  }) async {
    try {
      // 1. Check the username first so the user gets a clear message
      final available = await supabase.rpc(
        'username_available',
        params: {'p_username': username.trim()},
      );
      if (available != true) {
        return {"success": false, "message": "That username is already taken."};
      }

      // 2. Create the account. The keys in `data` must be spelled exactly like
      //    this - the database trigger reads them to fill "User" and "citizen".
      final authResponse = await supabase.auth.signUp(
        email: email.trim(),
        password: password,
        data: {
          'username': username.trim(),
          'firstname': firstname.trim(),
          'surname': surname.trim(),
          'phonenumber': '+27${phone.trim()}', // form collects the 9 digits after +27
          'residence': residence.trim(),
        },
      );

      final user = authResponse.user;
      if (user == null) {
        return {"success": false, "message": "Sign up failed."};
      }
      // With "Confirm email" turned on, Supabase does not return an error for an
      // email that is already registered - it returns a user with no identities.
      if (user.identities != null && user.identities!.isEmpty) {
        return {"success": false, "message": "An account with this email already exists."};
      }

      // signUp logs the new user in straight away (when "Confirm email" is off).
      // Sign out so they log in themselves on the login page.
      if (authResponse.session != null) {
        await supabase.auth.signOut();
      }

      return {"success": true, "message": "User successfully registered"};
    } on AuthWeakPasswordException {
      return {"success": false, "message": "Password is too weak."};
    } on AuthException catch (e) {
      if (e.code == 'user_already_exists' || e.code == 'email_exists') {
        return {"success": false, "message": "An account with this email already exists."};
      }
      if (e.message.contains('Database error saving new user')) {
        // The sign-up trigger rejected the data (username taken or invalid)
        return {
          "success": false,
          "message": "Username is invalid or already taken. Use 3-30 letters, numbers, _ or .",
        };
      }
      return {"success": false, "message": e.message};
    } on PostgrestException catch (e) {
      return {"success": false, "message": e.message};
    } catch (e) {
      return {"success": false, "message": e.toString()};
    }
  }

  // ------------------------------------------------------------------- LOGIN
  /// On success the result also contains "profile":
  /// {userid, username, firstname, surname, role} where role is
  /// 'citizen', 'investigator' or 'admin'.
  Future<Map<String, dynamic>> loginUser({
    required String username,
    required String password,
  }) async {
    // Same message for a wrong username or a wrong password, so the login
    // screen does not reveal which usernames exist.
    const badLogin = "Invalid username or password.";
    try {
      final email = await supabase.rpc(
        'email_for_username',
        params: {'p_username': username.trim()},
      );
      if (email is! String) {
        return {"success": false, "message": badLogin};
      }

      final authResponse = await supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );

      final profile = await supabase
          .from('User')
          .select('userid, username, firstname, surname, role')
          .eq('authid', authResponse.user!.id)
          .single();

      return {
        "success": true,
        "message": "Welcome ${profile['firstname']}",
        "profile": profile,
      };
    } on AuthException catch (e) {
      if (e.code == 'email_not_confirmed') {
        return {"success": false, "message": "Please confirm your email address first."};
      }
      return {"success": false, "message": badLogin};
    } on PostgrestException catch (e) {
      return {"success": false, "message": e.message};
    } catch (e) {
      return {"success": false, "message": e.toString()};
    }
  }

  // ------------------------------------------------------------------ LOGOUT
  Future<void> logout() => supabase.auth.signOut();
}
