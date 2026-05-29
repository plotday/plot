import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/app_info.dart';
import 'package:plot/notifications/notification_display.dart';
import 'package:plot/notifications/notification_service.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/onboarding.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/developer_mode.dart';
import 'package:plot/util/time_service.dart';
import 'package:plot/widget/modal.dart';
import 'command.dart';

/// TEMPORARY: when true, suppresses the Debug command group entirely so a
/// local debug build behaves like an App Store release build for App Store
/// review screenshots. Flip back to `false` before committing.
const bool _hideForAppStoreReviewScreenshots = true;

/// Build the debug command group if available in the current mode.
/// Returns null if neither kDebugMode nor DeveloperMode is enabled.
StaticCommandGroup? buildDebugCommands() {
  if (_hideForAppStoreReviewScreenshots) return null;
  if (!kDebugMode && !DeveloperMode.isEnabled) return null;
  return StaticCommandGroup(
    title: 'Debug',
    commands: [
      TimeTravel(),
      if (Time.isFrozen()) UnfreezeTime(),
      RestartOnboarding(),
      TriggerTestPush(),
      ShowTestNotification(),
      TestNotificationNavigation(),
      DiagnosePushNotifications(),
    ],
  );
}

/// Resets the onboarding completion flag and re-shows the flow from step 0.
/// Useful for designers/developers iterating on onboarding copy and layout.
class RestartOnboarding extends Command {
  RestartOnboarding()
    : super(
        title: 'Restart onboarding',
        subtitle: 'Replay the onboarding flow from the first step',
        icon: FontAwesomeIcons.arrowRotateLeft,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await context.read<OnboardingBloc>().restart();
      return CommandMessage('Onboarding restarted');
    } catch (e) {
      return CommandMessage('Failed to restart onboarding: $e', isError: true);
    }
  }
}

/// Command to freeze time to a specific date/time for testing and screenshots.
class TimeTravel extends ShowPage {
  TimeTravel()
    : super(
        title: 'Time travel',
        icon: FontAwesomeIcons.clock,
        builder: (context) => _TimeTravelPage(),
      );
}

/// Command to unfreeze time and return to live time.
class UnfreezeTime extends Command {
  UnfreezeTime()
    : super(
        title: 'Unfreeze time',
        subtitle: 'Return to live time',
        icon: FontAwesomeIcons.clockRotateLeft,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    Time.unfreeze();
    return CommandMessage('Time unfrozen - returned to live time');
  }
}

/// Command to send a test push notification to the current device.
class TriggerTestPush extends Command {
  TriggerTestPush()
    : super(
        title: 'Trigger test push',
        subtitle: 'Send a sync_wake push to this device',
        icon: FontAwesomeIcons.bell,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final result = await api.post<Map<String, dynamic>>(
        '/test/trigger-push',
        body: {},
      );
      final sent = result['sent'] as int? ?? 0;
      return CommandMessage('Push sent to $sent device${sent == 1 ? '' : 's'}');
    } catch (e) {
      return CommandMessage('Failed to trigger push: $e', isError: true);
    }
  }
}

/// Command to directly show a local notification, bypassing FCM entirely.
/// Use this to verify notification display works before debugging the pipeline.
class ShowTestNotification extends Command {
  ShowTestNotification()
    : super(
        title: 'Show test notification',
        subtitle: 'Display a local notification immediately (no FCM)',
        icon: FontAwesomeIcons.solidBell,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await NotificationDisplay.instance.initialize();
      await showSummaryNotifications([
        {
          'title': 'Plot',
          'body': 'Test notification — direct display test',
          'target_priority_id': '',
          'urgent': false,
        },
      ]);
      return CommandMessage('Notification shown');
    } catch (e) {
      return CommandMessage('Failed: $e', isError: true);
    }
  }
}

/// Shows a macOS notification that, when clicked, triggers the same navigation
/// path as a mobile push notification tap. Use to debug notification→activity
/// navigation on desktop.
class TestNotificationNavigation extends Command {
  TestNotificationNavigation()
    : super(
        title: 'Test notification navigation',
        subtitle: 'Show a notification that navigates to activity on click',
        icon: FontAwesomeIcons.arrowUpRightFromSquare,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final nowBloc = context.read<NowBloc>();
      if (nowBloc.loading) {
        return CommandMessage('NowBloc not loaded yet', isError: true);
      }
      final priorityId = nowBloc.loadedState.defaultPriority.id.toString();

      await NotificationDisplay.instance.initialize();

      if (Platform.isMacOS) {
        await NotificationDisplay.instance.requestMacOSPermission();
      }
      if (Platform.isAndroid) {
        await NotificationDisplay.instance.requestAndroidPermission();
      }

      await NotificationDisplay.instance.showBatchNotification(
        id: 99999,
        title: 'Debug: tap to navigate',
        body: 'Should open activity tab for current priority',
        targetPriorityId: priorityId,
        urgent: true,
      );
      return CommandMessage('Notification shown — tap it to test navigation');
    } catch (e) {
      return CommandMessage('Failed: $e', isError: true);
    }
  }
}

/// Diagnostic command that checks every step of the push notification pipeline
/// and reports exactly where it fails.
class DiagnosePushNotifications extends Command {
  DiagnosePushNotifications()
    : super(
        title: 'Diagnose push notifications',
        subtitle: 'Check FCM token, permissions, and registration',
        icon: FontAwesomeIcons.stethoscope,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final lines = <String>[];

    // 1. Platform check
    final platform = Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : 'other');
    lines.add('Platform: $platform');
    lines.add('Supported: ${NotificationService.isSupported}');
    if (!NotificationService.isSupported) {
      return CommandMessage(lines.join('\n'), isError: true);
    }

    // 2. Permission status
    try {
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.getNotificationSettings();
      lines.add('Permission: ${settings.authorizationStatus.name}');
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        lines.add('BLOCKED: Permission denied — user must grant in system settings');
        return CommandMessage(lines.join('\n'), isError: true);
      }
    } catch (e) {
      lines.add('Permission check FAILED: $e');
      return CommandMessage(lines.join('\n'), isError: true);
    }

    // 3. FCM token
    String? fcmToken;
    try {
      fcmToken = await FirebaseMessaging.instance.getToken();
      if (fcmToken != null) {
        lines.add('FCM token: ${fcmToken.substring(0, 20)}...');
      } else {
        lines.add('FCM token: NULL — Firebase may not be configured correctly');
        return CommandMessage(lines.join('\n'), isError: true);
      }
    } catch (e) {
      lines.add('FCM token FAILED: $e');
      return CommandMessage(lines.join('\n'), isError: true);
    }

    // 4. SharedPreferences state
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('notification_user_id');
      final apiRoot = prefs.getString('api_root');
      final clerkKey = prefs.getString('clerk_publishable_key');
      lines.add('Prefs user_id: ${userId != null ? '${userId.substring(0, 8)}...' : 'NULL'}');
      lines.add('Prefs api_root: ${apiRoot ?? 'NULL'}');
      lines.add('Prefs clerk_key: ${clerkKey != null ? 'set' : 'NULL'}');
    } catch (e) {
      lines.add('SharedPreferences FAILED: $e');
    }

    // 5. Service state
    final svc = NotificationService.instance;
    lines.add('Service registered: ${svc.isTokenRegistered}');
    lines.add('Permission denied: ${svc.isPermissionDenied}');

    // 6. Try registering the token now
    try {
      await api.put<Map<String, dynamic>>('/device', body: {
        'platform': platform,
        'pushToken': fcmToken,
        'appVersion': '${AppInfo.version}+${AppInfo.buildNumber}',
      });
      lines.add('Token registration: SUCCESS');
    } catch (e) {
      lines.add('Token registration FAILED: $e');
    }

    return CommandMessage(lines.join('\n'));
  }
}

class _TimeTravelPage extends StatefulWidget {
  @override
  State<_TimeTravelPage> createState() => _TimeTravelPageState();
}

class _TimeTravelPageState extends State<_TimeTravelPage> {
  late FCalendarController<DateTime?> _calendarController;
  late TextEditingController _hourController;
  late TextEditingController _minuteController;
  DateTime? _selectedDate;
  int _selectedHour = 12;
  int _selectedMinute = 0;

  @override
  void initState() {
    super.initState();
    // Use frozen time if available, otherwise current time
    final initial = Time.now();
    _selectedDate = DateTime(initial.year, initial.month, initial.day);
    _selectedHour = initial.hour;
    _selectedMinute = initial.minute;

    _calendarController = FCalendarController.date(initial: _selectedDate);

    _hourController = TextEditingController(
      text: _selectedHour.toString().padLeft(2, '0'),
    );
    _minuteController = TextEditingController(
      text: _selectedMinute.toString().padLeft(2, '0'),
    );

    // Listen to text field changes to update hour/minute as user types
    _hourController.addListener(_onHourChanged);
    _minuteController.addListener(_onMinuteChanged);
  }

  void _onHourChanged() {
    final value = _hourController.text;
    final hour = int.tryParse(value);
    if (hour != null && hour >= 0 && hour <= 23) {
      setState(() {
        _selectedHour = hour;
      });
    }
  }

  void _onMinuteChanged() {
    final value = _minuteController.text;
    final minute = int.tryParse(value);
    if (minute != null && minute >= 0 && minute <= 59) {
      setState(() {
        _selectedMinute = minute;
      });
    }
  }

  @override
  void dispose() {
    _hourController.removeListener(_onHourChanged);
    _minuteController.removeListener(_onMinuteChanged);
    _hourController.dispose();
    _minuteController.dispose();
    super.dispose();
  }

  void _freezeTime() {
    if (_selectedDate == null) {
      Modal.pop(
        context,
        Value(CommandMessage('Please select a date', isError: true)),
      );
      return;
    }

    try {
      final frozenTime = DateTime(
        _selectedDate!.year,
        _selectedDate!.month,
        _selectedDate!.day,
        _selectedHour,
        _selectedMinute,
      );

      Time.setFrozenTime(frozenTime);
      Modal.pop(context, Value(CommandMessage('Time frozen to $frozenTime')));
    } catch (e) {
      Modal.pop(
        context,
        Value(CommandMessage('Failed to freeze time: $e', isError: true)),
      );
    }
  }

  void _unfreezeTime() {
    Time.unfreeze();
    Modal.pop(
      context,
      Value(CommandMessage('Time unfrozen - returned to live time')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: context.theme.spacing.padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Time travel',
                style: context.theme.typography.xl2.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

            // Status
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                Time.isFrozen()
                    ? 'Currently frozen to: ${Time.now()}'
                    : 'Currently: Live time',
                style: context.theme.typography.sm.copyWith(
                  color: context.theme.plotColors.muted,
                ),
              ),
            ),

            // Calendar
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Center(
                child: FCalendar(
                  control: .managedDate(controller: _calendarController),
                  style: FCalendarStyleDelta.delta(
                    decoration: DecorationDelta.value(const BoxDecoration()),
                  ),
                  onPress: (date) {
                    setState(() {
                      _selectedDate = date;
                    });
                  },
                ),
              ),
            ),

            // Time picker
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hour',
                          style: context.theme.typography.sm.copyWith(
                            color: context.theme.plotColors.muted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        FTextField(
                          control: .managed(controller: _hourController),
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Minute',
                          style: context.theme.typography.sm.copyWith(
                            color: context.theme.plotColors.muted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        FTextField(
                          control: .managed(controller: _minuteController),
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Actions
            Row(
              children: [
                Expanded(
                  child: FButton(
                    onPress: _freezeTime,
                    variant: FButtonVariant.primary,
                    child: const Text('Freeze Time'),
                  ),
                ),
                if (Time.isFrozen()) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: FButton(
                      onPress: _unfreezeTime,
                      variant: FButtonVariant.secondary,
                      child: const Text('Unfreeze'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
