import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/state/accounts.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/auth_button.dart';

class AuthAccountPage extends StatefulWidget {
  const AuthAccountPage({super.key});

  @override
  State<AuthAccountPage> createState() => AuthAccountPageState();
}

class AuthAccountPageState extends State<AuthAccountPage> {
  bool _loading = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AccountsBloc, AccountsState>(
      builder: (context, state) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AuthButton(
                onSignIn: (providerAuth) async {
                  if (providerAuth.code == null) {
                    print("Missing auth code");
                    setState(() {
                      _error = 'Authorization failed.';
                    });
                    return;
                  }
                  try {
                    setState(() {
                      _loading = true;
                      _error = null;
                    });
                    await Account.add(
                      AccountProvider.google,
                      providerAuth.code!,
                    );
                  } on Exception catch (e) {
                    print(e);
                    setState(() {
                      _error = 'Failed to sync.';
                    });
                  } finally {
                    setState(() {
                      _loading = false;
                    });
                  }
                },
                scopes: const [
                  'openid',
                  'profile',
                  'https://www.googleapis.com/auth/calendar.events',
                  'https://www.googleapis.com/auth/calendar.calendarlist.readonly',
                ],
              ),
              const SizedBox(height: 8),
              if (_loading) const Spinner.message('Syncing calendar'),
              if (_error != null) Text(_error!),
            ],
          ),
        );
      },
    );
  }
}
