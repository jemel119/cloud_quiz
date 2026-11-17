import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'trivia_preview.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const CloudQuizApp());
}

class CloudQuizApp extends StatefulWidget {
  const CloudQuizApp({super.key});

  @override
  State<CloudQuizApp> createState() => _CloudQuizAppState();
}

class _CloudQuizAppState extends State<CloudQuizApp> {
  late final Stream<User?> _authState = FirebaseAuth.instance
      .authStateChanges();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Class A Cloud Quiz',
      home: Scaffold(
        appBar: AppBar(title: const Text('Class A Cloud Quiz')),
        body: SafeArea(
          child: StreamBuilder<User?>(
            stream: _authState,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Center(
                  child: Text('Could not check your sign-in.'),
                );
              }

              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final user = snapshot.data;
              if (user == null) return const SignInForm();

              return ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const Text('Signed in'),
                  SelectableText('UID: ${user.uid}'),
                  const SizedBox(height: 16),
                  TriviaPreview(key: ValueKey(user.uid), uid: user.uid),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () async {
                      try {
                        await FirebaseAuth.instance.signOut();
                      } on FirebaseAuthException {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Could not sign out. Try again.'),
                          ),
                        );
                      }
                    },
                    child: const Text('Sign out'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class SignInForm extends StatefulWidget {
  const SignInForm({super.key});

  @override
  State<SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends State<SignInForm> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _signingIn = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_signingIn || !_formKey.currentState!.validate()) return;

    setState(() {
      _signingIn = true;
      _error = null;
    });

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = switch (error.code) {
          'network-request-failed' =>
            'Could not connect. Check your internet connection and try again.',
          'too-many-requests' => 'Too many attempts. Wait before trying again.',
          'invalid-email' => 'Enter a valid email address.',
          'invalid-credential' ||
          'wrong-password' ||
          'user-not-found' => 'Sign-in failed. Check your email and password.',
          _ => 'Sign-in is unavailable. Try again.',
        };
      });
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextFormField(
            controller: _email,
            enabled: !_signingIn,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Email'),
            validator: (value) =>
                (value ?? '').trim().isEmpty ? 'Enter your email.' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _password,
            enabled: !_signingIn,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
            validator: (value) =>
                (value ?? '').isEmpty ? 'Enter your password.' : null,
            onFieldSubmitted: (_) => _signIn(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _signingIn ? null : _signIn,
            child: Text(_signingIn ? 'Signing in…' : 'Sign in'),
          ),
        ],
      ),
    );
  }
}
