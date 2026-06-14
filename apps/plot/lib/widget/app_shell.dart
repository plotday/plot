import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/global.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/note_viewer.dart';
import 'package:plot/state/otp_prompt_controller.dart';
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
  late final OtpPromptController _otpController;

  @override
  void initState() {
    super.initState();
    AppContext.register(_contextKey);
    _otpController = OtpPromptController(Store.get);
  }

  @override
  void dispose() {
    _otpController.dispose();
    AppContext.unregister(_contextKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FToaster(
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
    );
  }
}
