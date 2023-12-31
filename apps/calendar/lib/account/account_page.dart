import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabase = Supabase.instance.client;

class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            ElevatedButton(
                onPressed: () async {
                  try {
                    await supabase.auth.signOut();
                  } on AuthException catch (e) {
                    SnackBar(
                      content: Text(e.message),
                      backgroundColor: Theme.of(context).colorScheme.error,
                    );
                  }
                },
                child: const Text('Sign Out')),
          ],
        ),
      ),
    );
  }
}
