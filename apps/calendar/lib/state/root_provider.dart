import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/user.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/accounts.dart';
import 'package:plot/state/context.dart';
import 'package:plot/model/session.dart' as plot_session;
import 'package:plot/model/context.dart';
import 'package:plot/model/account.dart';
import 'package:plot/platform/spinner.dart';
import 'package:plot/widget/global_menu.dart';

class RootProvider extends StatefulWidget {
  const RootProvider({required this.child, super.key});

  @override
  RootProviderState createState() => RootProviderState();

  final Widget child;
}

class RootProviderState extends State<RootProvider> {
  Future<void>? _dataLoading;
  late StreamSubscription<UserState> _blocSubscription;

  void _onUserStateChange(UserState state) {
    if (state is UserSignedIn) {
      setState(() {
        _dataLoading = Future.wait([
          Account.store.load(),
          Context.store.load(),
          plot_session.Session.store.load(),
        ]);
      });
    } else {
      setState(() {
        _dataLoading = null;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _onUserStateChange(context.read<UserBloc>().state);
    _blocSubscription =
        context.read<UserBloc>().stream.listen(_onUserStateChange);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _dataLoading,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text("Error loading data"));
        }
        if (!snapshot.hasData) {
          return const Center(child: Spinner());
        }
        return MultiBlocProvider(
          providers: [
            BlocProvider(create: (_) => NowBloc()),
            BlocProvider(create: (_) => AccountsBloc()),
            BlocProvider(create: (_) => ContextBloc()),
          ],
          child: GlobalMenu(child: widget.child),
        );
      },
    );
  }

  @override
  void dispose() {
    _blocSubscription.cancel();
    super.dispose();
  }
}
