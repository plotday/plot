import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/global.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/note_viewer.dart';
import 'package:plot/state/otp_prompt_controller.dart';
import 'package:plot/state/user.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/onboarding/onboarding_overlay.dart';
import 'package:plot/widget/otp_toast.dart';
import 'app_context.dart';
import 'modal.dart';

@RoutePage(name: 'AppShellRoute')
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final GlobalKey _contextKey = GlobalKey();
  final OtpPromptController _otpController = OtpPromptController();

  @override
  void initState() {
    super.initState();
    AppContext.register(_contextKey);
    // The OTP/confirm toast watches the user's notes, which needs an open
    // Store. AppShell is the persistent root shell and mounts before sign-in
    // (it hosts SignInRoute), so attach only when a Store already exists (a
    // returning user whose Store.start ran before this mount). The UserBloc
    // listener in [build] (re)attaches on sign-in and detaches on sign-out.
    if (Store.isAvailable) _otpController.attach(Store.get);
  }

  @override
  void dispose() {
    _otpController.dispose();
    AppContext.unregister(_contextKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<UserBloc, UserState>(
      // Bind the OTP note-watch to the Store's lifetime: attach when the user
      // becomes ready (Store.start has run by then) and detach on sign-out
      // before the Store is stopped. Keeps AppShell from reading Store.get
      // while signed out.
      listener: (context, state) {
        if (state is UserReady && Store.isAvailable) {
          _otpController.attach(Store.get);
        } else if (state is UserSignedOut) {
          _otpController.detach();
        }
      },
      child: FToaster(
        child: ModalProvider(
        child: Container(
          key: _contextKey,
          child: GlobalShortcuts(
            child: LayoutStateProvider(
              child: BlocProvider(
                create: (_) => NoteViewerBloc(),
                child: OnboardingOverlay(
                  child: Stack(
                    children: [
                      AutoRouter(
                        placeholder: (context) => const LoadingPage(),
                      ),
                      // OTP / confirm-account toast — declarative overlay
                      // driven by OtpPromptController.current. Sits above the
                      // router content but below forui toasts (which use the
                      // FToaster overlay inserted above this Stack).
                      Positioned(
                        top: 16,
                        right: 16,
                        child: SafeArea(
                          child: ValueListenableBuilder<OtpPrompt?>(
                            valueListenable: _otpController.current,
                            builder: (context, prompt, _) {
                              if (prompt == null) return const SizedBox.shrink();
                              return OtpToast(
                                prompt: prompt,
                                onDismiss: _otpController.dismiss,
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }
}
