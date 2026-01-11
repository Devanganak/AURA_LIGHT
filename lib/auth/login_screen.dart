import 'package:flutter/material.dart';
import '../main.dart';
import 'signup_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';




class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  bool isEmailValid = false;
  bool isPasswordValid = false;
  bool isPasswordVisible = false;

  bool _isValidEmail(String email) {
    return RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(email);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.green.shade900,
              Colors.green.shade600,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 60),

              // APP ICON
              const Icon(
                Icons.visibility_off,
                size: 80,
                color: Colors.white,
              ),
              const SizedBox(height: 12),

              // APP NAME
              const Text(
                'Auralight',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 6),
              Text(
                'Your Visual Assistant',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 14,
                ),
              ),

              const SizedBox(height: 50),

              // WHITE CARD
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(30),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Login',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: Colors.green.shade900,
                          ),
                        ),
                        const SizedBox(height: 6),

                        Text(
                          'Sign in to continue',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 30),

                        // EMAIL FIELD
                        TextField(
                          controller: emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: InputDecoration(
                            labelText: 'Email',
                            prefixIcon: const Icon(Icons.email),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            errorText: emailController.text.isEmpty
                                ? null
                                : (isEmailValid
                                    ? null
                                    : 'Enter a valid email'),
                          ),
                          onChanged: (value) {
                            setState(() {
                              isEmailValid = _isValidEmail(value);
                            });
                          },
                        ),
                        const SizedBox(height: 18),

                        // PASSWORD FIELD WITH 👁️ + 8 CHAR RULE
                        TextField(
                          controller: passwordController,
                          obscureText: !isPasswordVisible,
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: const Icon(Icons.lock),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            helperText: 'Minimum 8 characters',
                            errorText: passwordController.text.isEmpty
                                ? null
                                : (isPasswordValid
                                    ? null
                                    : 'Password must be at least 8 characters'),
                            suffixIcon: IconButton(
                              icon: Icon(
                                isPasswordVisible
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                                color: Colors.black87,
                              ),
                              onPressed: () {
                                setState(() {
                                  isPasswordVisible = !isPasswordVisible;
                                });
                              },
                            ),
                          ),
                          onChanged: (value) {
                            setState(() {
                              isPasswordValid = value.length >= 8;
                            });
                          },
                        ),
                        const SizedBox(height: 30),

                        // LOGIN BUTTON (DISABLED UNTIL VALID)
                        ElevatedButton(
                          onPressed: (isEmailValid && isPasswordValid)
    ? () async {
        try {
          // 🔐 FIREBASE LOGIN
          final UserCredential userCredential =
              await FirebaseAuth.instance.signInWithEmailAndPassword(
            email: emailController.text.trim(),
            password: passwordController.text.trim(),
          );

          // ✅ CONFIRM LOGIN
          print("LOGIN SUCCESS");
          print("EMAIL: ${userCredential.user?.email}");
          print("UID: ${userCredential.user?.uid}");

          // ➡️ GO TO HOME
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => BillReaderScreen(),

            ),
          );
        } on FirebaseAuthException catch (e) {
          // ❌ SHOW ERROR
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(e.message ?? 'Login failed'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    : null,

                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green.shade700,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'LOGIN',
                            style: TextStyle(fontSize: 16),
                          ),
                        ),
                        const SizedBox(height: 16),

                        TextButton(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const SignUpScreen(),
                              ),
                            );
                          },
                          child: Text(
                            "Don't have an account? Sign up",
                            style: TextStyle(
                              color: Colors.green.shade700,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
