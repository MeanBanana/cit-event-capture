import 'package:flutter/material.dart';
import 'register_citizen.dart';

class LoginPage extends StatefulWidget{
  const LoginPage({super.key});

  @override
  State<LoginPage>  createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>{
  final TextEditingController userNameController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.center,
              child: Text(
                  "Argus Shield",
                  style: TextStyle(
                    fontSize: 30,
                    color: Colors.white,
                    fontFamily: 'CourierPrime',
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ),

            Align(
              alignment: Alignment.center,
                child:Text(
                  "CIT Intelligence System",
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white,
                  fontFamily: 'CourierPrime',
                ),
              ),
            ),
          ],
        ),
        backgroundColor: Color(0xFF11192A) ,
      ),
      body:
        Padding(
          padding: EdgeInsets.symmetric(vertical: 30, horizontal: 30),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                "Login",
                style: TextStyle(
                  fontSize: 50,
                  color: Colors.white,
                  fontFamily: 'CourierPrime',
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 30),

              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Username",
                  style: TextStyle(
                    fontSize: 20,
                    color: Colors.white,
                    fontFamily: 'CourierPrime',
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              TextField(
                controller: userNameController,
                style: TextStyle(
                  color: Colors.white,
                ),
                decoration: InputDecoration(
                 border: OutlineInputBorder(),
               ),
              ),

              const SizedBox(height: 30),


              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Password",
                  style: TextStyle(
                    fontSize: 20,
                    color: Colors.white,
                    fontFamily: 'CourierPrime',
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              TextField(
                controller: passwordController,
                obscureText: true,
                style: TextStyle(
                  color: Colors.white,
                ),
                decoration: InputDecoration(
                  border: OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 10),

              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                    onPressed: () {},         //Add functionality for the forgot password button
                    child: Text(
                        "Forgot password?",
                        style: TextStyle(
                          fontSize: 20,
                          color: Colors.orangeAccent,
                          fontFamily: 'Inter',
                        ),
                    ),
                ),
              ),

              const SizedBox(height:60),

              TextButton(
                onPressed: (){
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => RegisterPage()),
                  );
                },
                child: Text(
                  "Register as citizen",
                  style: TextStyle(
                    fontSize: 20,
                    color: Colors.orangeAccent,
                    decoration: TextDecoration.underline,
                    decorationColor: Colors.orangeAccent,
                    decorationThickness: 2,
                    fontFamily: 'Inter',
                  ),
                ),
              ),

              const SizedBox(height:20),

              SizedBox(
                width: 400,
                height:70,
                child: FloatingActionButton(
                  onPressed: (){},
                  backgroundColor: Colors.orangeAccent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero,
                  ),
                    child: Text(
                      "Access System",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                ),
              ),

              const SizedBox(height: 15),

              Text(
                "Argus Shield . Secure Access . SAPS Authorised",
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.black,
                )
              )
            ],
          ),
        ),
        backgroundColor: Color(0xFF192536),
    );
  }

}

