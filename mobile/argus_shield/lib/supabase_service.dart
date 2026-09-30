import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {

  final supabase = Supabase.instance.client;

  Future<Map<String, dynamic>> registerUser({
    required String firstname,
    required String surname,
    required String username,
    required String email,
    required String phone,
    required String residence,
    required String password,
}) async {
    try{

      final authResponse = await supabase.auth.signUp(
        email: email,
        password: password,
      );

      if (authResponse.user == null){
        return {"success": false, "message": "Sign up failed."};
      }

      final userID = authResponse.user!.id;

      final insertResponse = await supabase.from('User').insert({
        'authid': userID,
        'firstname': firstname,
        'surname': surname,
        'email': email,
        'phonenumber': phone,
        'role': "citizen",
        'username': username
      }).select('userid');

      final newUserID = insertResponse[0]['userid'];

      await supabase.from('citizen').insert({
        'userid': newUserID,
        'role': "citizen",
        'residence': residence
      });

      return {"success": true, "message": "User successfully registered"};
    }on PostgrestException catch (e){
      if (e.message.contains('duplicate key')) {
        return {"success": false, "message": "Email or username already exists"};
      }
      return {"success": false, "message": e.message};
    }catch (e){
      return {"success": false, "message": e.toString()};
    }
  }

}