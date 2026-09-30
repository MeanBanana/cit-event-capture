import 'package:flutter/material.dart';
import 'login.dart';
import 'package:supabase_flutter/supabase_flutter.dart';


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
   await Supabase.initialize(
     url: 'https://tnydrlxptqegzhbvwpcq.supabase.co',
     anonKey: 'sb_publishable_qyDg3_F69Cy2rpoWDvR-7A_Z3AXR8h3',
  );
  runApp(RootApp());
}

class RootApp extends StatelessWidget {
  const RootApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: LoginPage(),
    );
  }


}




