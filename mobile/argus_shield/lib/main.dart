import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login.dart';
import 'theme/app_theme.dart';
import 'admin_screens/admin_dashboard.dart';



//Commented the section below out, to individually test admin screens without logging in for now, see below
//CAREL, read above



/*
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://tnydrlxptqegzhbvwpcq.supabase.co',
    anonKey: 'sb_publishable_qyDg3_F69Cy2rpoWDvR-7A_Z3AXR8h3',
  );
  runApp(const RootApp());
}


class RootApp extends StatelessWidget {
  const RootApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Argus Shield',
      debugShowCheckedModeBanner: false,
      // All colours, fonts and widget styles come from theme/app_theme.dart
      theme: buildArgusTheme(),
      home: const LoginPage(),
    );
  }
}

 */


//I use this main to test the admin screen without logging in for now,
 void main() {
   runApp(
     MaterialApp(
       title: 'Argus Shield',
       debugShowCheckedModeBanner: false,
       theme: buildArgusTheme(),
       home: const AdminDashboard(), //This is a dashboard screen under dahsboard, it is the holder screen
       //that houses the individual screens of admin, but same header is applied, additionally we can have same session
       //aslo be created here so user session lives through all screens, so just calling it will give screen without login
     ),
  );
 }