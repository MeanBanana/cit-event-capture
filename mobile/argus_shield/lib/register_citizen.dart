import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'supabase_service.dart';
import 'login.dart';
import 'loadingscreen.dart';
import 'theme/app_theme.dart';
import 'theme/argus_widgets.dart';


class RegisterPage extends StatefulWidget{
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage>{
  final TextEditingController firstNameController = TextEditingController();
  final TextEditingController surnameController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController phoneNumberController = TextEditingController();
  final TextEditingController residenceController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController usernameController = TextEditingController();

  final _formKey = GlobalKey<FormState>();

  final service = SupabaseService();

  bool isChecked = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const ArgusAppBar(),
      body:Padding(
        // Only left/right here. Top/bottom padding sits inside the scroll
        // view below, so it scrolls with the form instead of leaving fixed
        // empty bands that cut the form off under the header and above the
        // phone's buttons.
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            // Small top gap to match the login page; a bit more at the bottom
            // so the Register button doesn't touch the edge.
            padding: const EdgeInsets.only(top: 4, bottom: 20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text(
                  "Register as citizen",
                  style: AppText.pageTitle,
                ),
  
                const SizedBox(height: 30),
  
                const FieldLabel("Firstname"),
                TextFormField(
                  controller: firstNameController,
                  decoration: const InputDecoration(),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty){
                      return "Firstname is required";
                    }else if (!RegExp(r"^[A-Za-zÀ-ÿ' \-]+$").hasMatch(value.trim())){
                      return "Firstname can only contain letters, spaces, hyphens and apostrophes.";
                    }
                    return null;
                  },
                ),
  
                const SizedBox(height: 10),
  
                const FieldLabel("Surname"),
                TextFormField(
                  controller: surnameController,
                  decoration: const InputDecoration(),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty){
                      return "Surname is required";
                    }else if (!RegExp(r"^[A-Za-zÀ-ÿ' \-]+$").hasMatch(value.trim())){
                      return "Surname can only contain letters, spaces, hyphens and apostrophes.";
                    }
                    return null;
                  },
                ),
  
                const SizedBox(height: 10),
  
                const FieldLabel("Email"),
                TextFormField(
                  controller: emailController,
                  decoration: const InputDecoration(),
                  validator: (value) {
                    if (value == null || value.isEmpty){
                      return "Email is required";
                    }else if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.trim())){
                      return "Enter a valid email address.";
                    }
                    return null;
                  },
                ),
  
                const SizedBox(height: 10),
  
                const FieldLabel("Phone number"),
                TextFormField(
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(9),
                  ],
                  controller: phoneNumberController,
                  decoration: const InputDecoration(prefixText: "+27 "),
                  validator: (value) {
                    if (value == null || value.isEmpty){
                      return "Phone is required";
                    }else if (value.length != 9){
                      return "Phone number must be 9 digits long, no initial 0 needed";
                    }
                    return null;
                  },
                ),
  
                const SizedBox(height: 10),
  
                const FieldLabel("Residence"),
                TextFormField(
                  controller: residenceController,
                  decoration: const InputDecoration(),
                  validator: (value){
                    if (value == null || value.isEmpty){
                      return "Residence is required.";
                    }
                    return null;
                  },
                ),
  
                const SizedBox(height: 10),

                const FieldLabel("Username"),
                TextFormField(
                  controller: usernameController,
                  decoration: const InputDecoration(),
                  validator: (value){
                    if (value == null || value.trim().isEmpty){
                      return "Username is required";
                    }else if (!RegExp(r'^[A-Za-z0-9_.]{3,30}$').hasMatch(value.trim())){
                      return "Username must be 3-30 characters: letters, numbers, _ or . only.";
                    }
                    return null;
                  },
                ),

                const SizedBox(height: 10),

                const FieldLabel("Password"),
                TextFormField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(),
                  validator: (value){
                    if (value == null || value.isEmpty){
                      return "Password is required.";
                    }else if (!RegExp(r'^(?=.*[A-Z])(?=.*\d)(?=.*[!@#$%^&*_\-+=]).{8,}$').hasMatch(value)){
                      return "Password requires one capital letter, one digit, and one special character and must at least be 8 characters long.";
                    }
                    return null;
                  },
                ),

                Align(
                  alignment: Alignment.centerLeft,
                  child: CheckboxListTile(
                    title: const Text(
                        "Terms and conditions",
                        style: AppText.checkboxLabel
                    ),
                    value: isChecked,
                    onChanged: (bool? value){
                      setState(() {
                        isChecked = value ?? false;
                      });
                    },
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: (){
                      showDialog(
                          context: context,
                          builder: (BuildContext context){
                            return AlertDialog(
                              title: const Text("TERMS AND CONDITIONS", style: AppText.sectionTitle),
                              content: SizedBox(
                                width: double.maxFinite,
                                height:MediaQuery.of(context).size.height * 0.6,
                                child: SingleChildScrollView(
                                child: TermsAndConditions(),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () {
                                    Navigator.of(context).pop();
                                  },
                                  child: Text(
                                    "Close T&Cs",
                                    style: TextStyle(
                                      fontFamily: AppFonts.body,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                )
                              ],
                              );
                          },
                      );
                    },
                    child: Text(
                      "View T&Cs",
                      style: TextStyle(
                        fontFamily: AppFonts.body,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
  
                PrimaryButton(
                  label: "Register Account",
                  onPressed: () async {
                      final ctx = context;
                      if (!_formKey.currentState!.validate()) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('Please correct errors')),
                        );
                        return;
                      }
                      if (!isChecked) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('Please accept the Terms and Conditions')),
                        );
                        return;
                      }

                      final result = await service.registerUser(firstname: firstNameController.text, surname: surnameController.text, username: usernameController.text, email: emailController.text, phone: phoneNumberController.text, residence: residenceController.text, password: passwordController.text);

                      if (!ctx.mounted) return;

                      final success = result["success"] == true;
                      Navigator.push(
                        ctx,
                        MaterialPageRoute(
                          builder: (_) => LoadingScreen(
                            resultMessage: success
                                ? "${result["message"]}. You can now log in."
                                : result["message"],
                            nextScreen: const LoginPage(), // or any screen you want
                          ),
                        ),
                      );
                    },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

}

class TermsAndConditions extends StatelessWidget{
  const TermsAndConditions({super.key});
  final String mdText="""1. Introduction and Acceptance

1.1 These Terms and Conditions ("Terms") govern your use of Argus Shield ("Argus", "the App", "the System"), a research prototype developed by [Deacs and team / Eduvos Bedfordview — confirm responsible party] as part of an Information Technology Capstone research project.

1.2 By creating an account and ticking the acceptance box, you confirm that you have read, understood and agreed to these Terms and to the processing of your personal information described in them. If you do not agree, please do not register or use the App.

1.3 You must be 18 years or older and legally able to enter into an agreement to register.

2. What Argus Is (and Is Not)

2.1 Argus is a system designed to help capture and organise suspect and vehicle intelligence from cash-in-transit (CIT) robbery scenes in South Africa. Citizens who witness or record such an incident may upload cellphone video footage together with a written description of the scene. An AI-based computer-vision service then analyses the footage, and authorised investigators review the results.

2.2 Argus is not an emergency service. It is not monitored in real time. If you are witnessing or in danger from a crime, contact the South African Police Service (SAPS) on 10111 or 112 from a cellphone immediately. Do not rely on Argus to report a crime in progress.

2.3 Argus is not connected to SAPS. The System is fully self-contained. Uploading footage to Argus does not amount to opening a SAPS case, laying a charge, or making an official witness statement, and it does not create a case number with SAPS or any other authority. [If the team later integrates with SAPS, update this clause.]

2.4 Argus is a research prototype. Features may change, be unavailable, or be withdrawn without notice.

3. Your Account

3.1 Registration. To submit footage you must first register an account. Anonymous submission is not supported. We ask for:

your full name;
your email address;
your mobile number (verified with a one-time PIN);
a password;
your acceptance of these Terms and your POPIA consent (recorded with the date and time).

3.2 Accurate information. You must provide true and current information and keep it updated.

3.3 Account security. You are responsible for keeping your password confidential and for all activity under your account. Tell us immediately at [contact email] if you suspect unauthorised access.

3.4 One person, one account. Do not share your account or register on behalf of someone else.

3.5 Roles. Everyone who registers through the public sign-up is assigned the Citizen role. The Administrator and Investigator roles are assigned only by authorised project staff and cannot be obtained through public registration.

4. Your Safety Comes First

4.1 Never put yourself or anyone else at risk to record footage. Do not approach a robbery scene, follow suspects or vehicles, or confront anyone in order to film them.

4.2 Only submit footage you recorded safely and lawfully, or footage you are otherwise entitled to submit.

4.3 We are not responsible for any harm you suffer as a result of recording or attempting to record an incident.

5. Rules for Submitting Footage and Descriptions

5.1 You agree that anything you submit:

is genuine and unaltered (no editing, staging, AI-generation or manipulation);
was recorded by you, or you have the right to submit it;
is submitted in good faith and to the best of your knowledge accurate;
does not include intimate, sexual or otherwise unlawful content.

5.2 You must not submit false, misleading or hoax reports, or use Argus to harass, defame or falsely accuse any person.

5.3 Please describe what you saw factually (what, where, when, and who or what you observed). Do not guess about people's identities or speculate about guilt.

5.4 We may reject, remove or restrict any submission or account that breaks these Terms, and may report unlawful activity to the appropriate authorities.

6. What Happens to Your Footage (How Argus Processes It)

6.1 Upload and storage. Your footage and description are stored securely using Supabase (authentication, database and file storage) [confirm hosting region — see clause 10].

6.2 AI analysis. When new footage is submitted, an automated Python-based computer-vision service is triggered to analyse it. Depending on the footage, the analysis may detect and record information such as vehicle details (for example make, colour, number plates) and descriptions of persons and events, and may involve facial or other biometric-type features of people visible in the video. The results are saved to the database and linked to your submission.

6.3 Human review. AI results are only an aid. They may be incomplete or wrong. Authorised Investigators review the footage and results, and Administrators manage cases and assign investigators. No one should treat an AI result as proof of identity or guilt.

6.4 No fully automated decisions. Argus does not make final decisions about any person. Outcomes depend on human review.

7. Personal Information We Collect and Why (POPIA Notice)

7.1 In terms of the Protection of Personal Information Act 4 of 2013 (POPIA), the responsible party is [name of Eduvos / project team — confirm], and the contact person for privacy matters (Information Officer or delegate) is [name, email, phone].

7.2 We collect and process the following:

Category	Examples	Purpose
Account information	Full name, email address, mobile number, password (stored in hashed form), role, consent record	To create and secure your account, verify you are a real, reachable person, and allow investigators to follow up
Submission content	Video footage, scene description, upload date and time, [location if you choose to provide it]	To let the System analyse and organise intelligence about a CIT robbery
Information in the footage	Images of suspects, vehicles, number plates, bystanders, and you (if visible); voices	To identify and record suspect and vehicle information for investigative use
AI analysis results	Detected vehicle and person attributes, timestamps, confidence scores	To support investigators' review
Technical and activity data	Login times, actions taken in the App	To secure the System and keep an audit trail

7.3 Special personal information. Footage may reveal information about alleged criminal behaviour and may involve biometric information of third parties. POPIA treats these as special personal information. We process it only for the purpose stated in this document and with the safeguards in clause 9.

7.4 Third parties in footage. People captured in footage (suspects and bystanders) have not consented individually. We handle their information because the processing is necessary for the purposes of detecting and investigating crime and protecting the legitimate interests of victims and the public. You should not deliberately capture or single out bystanders unrelated to the incident.

7.5 Minimum information. We do not ask for your ID number or home address at registration. Please do not include them, or other people's private details, in your description unless they are directly relevant to what you witnessed.

8. Who Can See Your Information

8.1 Administrators and Investigators (Argus project staff and authorised users) can see your account details and your submissions to the extent needed to manage and investigate cases.

8.2 Other citizens cannot see your identity, your footage or your description.

8.3 Service providers. Your information is hosted and processed using our technology provider Supabase and related infrastructure, under the safeguards described in clause 9. We do not sell your information or use it for advertising.

8.4 Law enforcement and legal disclosure. Because Argus is not linked to SAPS, footage is not sent to the police automatically. We may disclose information to SAPS, a court, or another authority when [the team has decided to refer a case / required by law, a subpoena or a court order]. We will limit disclosure to what is legally required or necessary.

8.5 Your identity as a witness. We will take reasonable steps to keep your identity confidential within the System. However, if the footage is used in legal proceedings, you may be identified or called as a witness, and we cannot promise anonymity in that situation.

8.6 Research use. Argus is part of an academic research project. Any use of information in reports, presentations or papers will be anonymised or aggregated so that you and the people in the footage cannot be identified, unless you have separately agreed otherwise.

9. Security and Retention

9.1 We use reasonable technical and organisational measures to protect your information, including encrypted connections, hashed passwords, role-based access controls, one-time-PIN verification and access logging. No system is completely secure, and we cannot guarantee that a breach will never happen.

9.2 If a security compromise affects your personal information, we will notify you and the Information Regulator as required by POPIA.

9.3 Retention. We keep account information while your account is active. We keep footage, descriptions and AI results for [retention period, e.g. the duration of the research project and any related investigation, then delete or anonymise]. Information needed for an open investigation or required by law may be kept longer.

10. Cross-Border Transfers

10.1 Our hosting provider may store or process data on servers outside South Africa [confirm the Supabase project region]. Where this happens, we will only transfer your information as POPIA allows, for example where the recipient is subject to comparable data-protection rules or you have consented. By accepting these Terms you consent to this transfer.

11. Your Rights

11.1 Under POPIA you may, subject to legal limits:

ask whether we hold your personal information and request a copy;
ask us to correct or delete inaccurate, outdated or unlawfully held information;
object to the processing of your personal information;
withdraw your consent at any time (this does not affect processing already done, and we may still need to keep information required for an investigation or by law);
complain to the Information Regulator (South Africa): [add current contact details from inforegulator.org.za].

11.2 To exercise your rights, contact [privacy contact email]. We may need to verify your identity first.

11.3 Once footage has been used in an active investigation, deletion may be restricted. We will explain why if we cannot delete something.

12. Intellectual Property and Licence

12.1 You keep ownership of the footage you record.

12.2 By submitting footage and descriptions, you give the Argus project a non-exclusive, royalty-free licence to store, copy, analyse, display to authorised users, and use them for the purposes in these Terms (crime analysis, investigation support and, in anonymised form, academic research).

12.3 The Argus name, logo, software and design belong to the project team and Eduvos as agreed between them. You may not copy or reverse-engineer them.

13. Acceptable Use of the App

13.1 You must not: attempt to access other users' data or restricted areas; upload malware; interfere with or overload the System; try to obtain Administrator or Investigator access; or use Argus for any unlawful purpose.

13.2 We may suspend or delete your account if you break these Terms or misuse the System.

14. Disclaimers and Limitation of Liability

14.1 Argus is a research prototype provided "as is". We give no guarantee that it will be available, error-free, secure or accurate, or that your submission will be reviewed within any time, lead to an investigation, or result in an arrest or conviction.

14.2 AI analysis may contain errors. We are not responsible for decisions made by others based on AI results.

14.3 To the fullest extent the law allows, the project team, Eduvos and its staff are not liable for any indirect or consequential loss, loss of data, or any harm arising from your use of Argus. Nothing in these Terms excludes liability that cannot lawfully be excluded, including under the Consumer Protection Act 68 of 2008 where it applies, or liability for gross negligence or intentional misconduct.

15. Changes, Termination and Governing Law

15.1 We may update these Terms. If we make a material change we will notify you in the App or by email, and you may be asked to accept the new version to keep using Argus.

15.2 You may close your account at any time by contacting [contact email]. We may end or suspend the project or your access at any time.

15.3 These Terms are governed by the laws of the Republic of South Africa. Any dispute will be dealt with by the courts of South Africa [confirm jurisdiction, e.g. Gauteng].

15.4 If any clause is found unenforceable, the rest of the Terms remain in force.""";

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
        data: mdText,
        styleSheet: MarkdownStyleSheet(
          h2: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          p: const TextStyle(fontSize: 16),
        ),
    );
  }

}
