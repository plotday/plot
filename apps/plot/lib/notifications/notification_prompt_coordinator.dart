import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/notifications/notification_prompt.dart';
import 'package:plot/notifications/notification_service.dart';
import 'package:plot/screenshot/scenes.dart';
import 'package:plot/state/onboarding.dart';
import 'package:plot/state/user.dart';
import 'package:plot/widget/confirm_modal.dart';
import 'package:plot/widget/toast.dart';

/// Decides *when* to surface the notification opt-in prompt. Mounted in the app
/// shell under `ModalProvider`, with `OnboardingBloc`/`UserBloc` in scope.
///
/// Fires once per launch when onboarding has resolved (`OnboardingCompleted`)
/// and the user is ready — and re-evaluates on resume so a system revocation
/// surfaces the re-enable modal. Renders nothing.
class NotificationPromptCoordinator extends StatefulWidget {
  const NotificationPromptCoordinator({super.key});

  @override
  State<NotificationPromptCoordinator> createState() =>
      _NotificationPromptCoordinatorState();
}

class _NotificationPromptCoordinatorState
    extends State<NotificationPromptCoordinator> with WidgetsBindingObserver {
  bool _modalOpen = false;

  /// Set once a prompt has been shown this app session. Prevents a dismissed
  /// (Esc / tap-away) prompt — which intentionally leaves state unchanged so it
  /// can reappear on a later launch — from re-showing on resume within the same
  /// session. Resets on the next launch (in-memory).
  bool _promptedThisSession = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Handle the already-completed case (returning users whose OnboardingBloc
    // resolved before this widget's BlocListener could observe the transition).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ob = context.read<OnboardingBloc?>()?.state;
      if (ob is OnboardingCompleted) _maybePrompt();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _maybePrompt();
  }

  Future<void> _maybePrompt() async {
    if (!mounted || _modalOpen || _promptedThisSession) return;
    if (Scenes.active) return; // never prompt during screenshot scenes
    if (context.read<UserBloc>().state is! UserReady) return;
    if (context.read<OnboardingBloc?>()?.state is! OnboardingCompleted) return;

    final action = await NotificationService.instance.evaluate();
    if (!mounted) return;
    switch (action) {
      case NotificationPromptAction.none:
        return;
      case NotificationPromptAction.showPriming:
        await _show(
          title: 'Stay on top of what matters',
          message: 'Get notified when important threads need your attention '
              '— even when Plot is closed.',
        );
      case NotificationPromptAction.showReEnable:
        await _show(
          title: 'Notifications are turned off',
          message: 'Turn them back on so Plot can alert you about important '
              'threads.',
        );
    }
  }

  Future<void> _show({required String title, required String message}) async {
    _modalOpen = true;
    _promptedThisSession = true;
    // Defaults to dismissed so an unexpected throw from the modal leaves state
    // unchanged (treated as a dismiss, not an opt-out).
    var outcome = ConfirmOutcome.dismissed;
    try {
      outcome = await ConfirmModal(
        title: title,
        message: message,
        confirmLabel: 'Enable notifications',
        cancelLabel: 'Not now',
      ).runDetailed(context);
    } finally {
      _modalOpen = false;
    }
    if (!mounted) return;

    switch (outcome) {
      case ConfirmOutcome.dismissed:
        // Accidental dismiss (Esc / tap outside): leave the per-device state
        // unchanged so the prompt can appear once more on a later launch. Not
        // re-shown this session (guarded by _promptedThisSession).
        return;
      case ConfirmOutcome.cancelled:
        // Explicit "Not now": stop auto-prompting on this device.
        await NotificationService.instance.declineFromUser();
        return;
      case ConfirmOutcome.confirmed:
        break;
    }

    final result = await NotificationService.instance.requestPermission();
    if (!mounted) return;
    switch (result) {
      case NotificationPermissionResult.granted:
        context.showToast(message: 'Notifications enabled');
      case NotificationPermissionResult.deniedPermanently:
        NotificationService.instance.openSystemNotificationSettings();
        context.showToast(
          message: 'Enable notifications in your device settings, then return '
              'to Plot.',
        );
      case NotificationPermissionResult.denied:
      case NotificationPermissionResult.unsupported:
      case NotificationPermissionResult.error:
        // Denial / unsupported / transient error — no error toast needed; the
        // Settings tile remains available.
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    // OnboardingBloc is optional in some shells (e.g. the signed-out shell that
    // hosts the sign-in route, which reads it nullably). When it's absent there
    // is nothing to listen to; once the user signs in, AppShell rebuilds with
    // the bloc in scope and the listener is wired up. Mirrors OnboardingOverlay's
    // own null guard.
    if (context.read<OnboardingBloc?>() == null) {
      return const SizedBox.shrink();
    }
    return BlocListener<OnboardingBloc, OnboardingState>(
      // Fire when onboarding resolves to completed (finished, skipped, or the
      // returning-user fast path). Guards inside _maybePrompt enforce once-only.
      listenWhen: (previous, current) =>
          current is OnboardingCompleted && previous is! OnboardingCompleted,
      listener: (context, _) => _maybePrompt(),
      child: const SizedBox.shrink(),
    );
  }
}
