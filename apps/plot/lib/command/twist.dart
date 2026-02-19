import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/widget/auth_button.dart'
    show getAuthProviderConfig, buildAuthButtonStyle;
import 'package:plot/store/store.dart';
import 'package:plot/state/now.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/api/twist_api.dart';
import 'package:plot/env.dart';
import 'package:plot/widget/widget.dart';
import 'logging.dart';

class ManageTwists extends ShowCommands {
  ManageTwists([Priority? priority])
    : super(
        title: 'Manage Twists',
        icon: PlotIcon.twist,
        commandsBuilder: (context) => _getTwistCommands(priority),
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      return await super.run(context);
    } on ApiException catch (e, t) {
      log.warning('Failed to load twists', e, t);
      return const CommandMessage(
        'Could not connect to Plot servers.',
        isError: true,
      );
    } on NetworkException catch (e, t) {
      log.warning('Failed to load twists', e, t);
      return const CommandMessage(
        'Could not connect to Plot servers.',
        isError: true,
      );
    }
  }

  static Future<Commands> _getTwistCommands(Priority? priority) async {
    final defaultPriority = priority ?? await Priority.getDefault();
    final results = await Future.wait([
      priority != null
          ? PriorityTwist.get(priority: priority, includeAncestors: false)
          : PriorityTwist.get(),
      TwistApi.getAllTwists(defaultPriority),
    ]);
    final priorityTwists = results[0] as List<PriorityTwist>;
    final allTwists = results[1] as List<Twist>;

    // Fetch priorities for each twist to get their paths
    final editCommandsFutures = priorityTwists.map((twist) async {
      final twistPriority = await Priority.getOne(twist.priorityId);
      return EditTwist(twist, priority: twistPriority);
    });
    final editCommands = await Future.wait(editCommandsFutures);

    // Sort active twists by name, then priority path, then environment
    editCommands.sort((a, b) {
      // Primary: alphabetical by name (case-insensitive)
      final nameComparison = a.priorityTwist.name.toLowerCase().compareTo(
        b.priorityTwist.name.toLowerCase(),
      );
      if (nameComparison != 0) return nameComparison;

      // Secondary: priority path (case-insensitive)
      final aPath = a.priority?.root == true
          ? ''
          : (a.priority?.ancestorsLabel() ?? a.priority?.title ?? '');
      final bPath = b.priority?.root == true
          ? ''
          : (b.priority?.ancestorsLabel() ?? b.priority?.title ?? '');
      final pathComparison = aPath.toLowerCase().compareTo(bPath.toLowerCase());
      if (pathComparison != 0) return pathComparison;

      // Tertiary: environment (public, review, private, personal)
      return _compareEnvironment(
        a.priorityTwist.twistEnvironment,
        b.priorityTwist.twistEnvironment,
      );
    });

    final addCommands = allTwists
        .map((twist) => ShowTwistInfo(twist, defaultPriority: priority))
        .toList();

    // Sort available twists by name, then environment
    addCommands.sort((a, b) {
      // Primary: alphabetical by name (case-insensitive)
      final nameComparison = a.twist.name.toLowerCase().compareTo(
        b.twist.name.toLowerCase(),
      );
      if (nameComparison != 0) return nameComparison;

      // Secondary: environment (public, review, private, personal)
      return _compareEnvironment(a.twist.environment, b.twist.environment);
    });

    return Commands(
      groups: [
        StaticCommandGroup(
          title: 'Active Twists',
          commands: editCommands.toList(),
        ),
        StaticCommandGroup(title: 'Available Twists', commands: addCommands),
      ],
    );
  }

  /// Compare environments in order: public, review, private, personal
  static int _compareEnvironment(String a, String b) {
    const envOrder = ['public', 'review', 'private', 'personal'];
    final aIndex = envOrder.indexOf(a);
    final bIndex = envOrder.indexOf(b);

    // If an environment is not in the list, put it at the end
    final aVal = aIndex == -1 ? envOrder.length : aIndex;
    final bVal = bIndex == -1 ? envOrder.length : bIndex;

    return aVal.compareTo(bVal);
  }
}

// ============================================================================
// Edit Twist (existing twist)
// ============================================================================

class EditTwist extends ShowForm {
  EditTwist(this.priorityTwist, {this.priority})
    : super(
        title: priorityTwist.name,
        subtitle: priority?.root == true
            ? null
            : (priority?.ancestorsLabel() ?? priority?.title),
        icon: PlotIcon.settings,
        form: (context) => _buildForm(context, priorityTwist, priority),
      );

  final PriorityTwist priorityTwist;
  final Priority? priority;

  static Future<FormData> _buildForm(
    BuildContext context,
    PriorityTwist priorityTwist,
    Priority? priority,
  ) async {
    try {
      // Load priority if not provided
      final loadedPriority =
          priority ?? await Priority.getOne(priorityTwist.priorityId);

      // Fetch all twists and integrations in parallel
      final results = await Future.wait([
        TwistApi.getAllTwists(loadedPriority),
        TwistApi.getIntegrations(priorityTwist.id.toString()),
      ]);
      final allTwists = results[0] as List<Twist>;
      final integrations = results[1] as TwistIntegrations;
      final matchingTwist = allTwists.firstWhere(
        (a) => a.id == priorityTwist.twistId.toString(),
        orElse: () => throw Exception('Twist not found'),
      );

      // Compute initially enabled syncables from server state
      final initialEnabled = integrations.syncables
          .where((s) => s.enabled)
          .map((s) => '${s.provider.name}:${s.id}')
          .toSet();

      final refreshNotifier = ValueNotifier<int>(0);
      var integrationChanges = IntegrationChanges(
        selectedSyncables: Set.of(initialEnabled),
      );

      return FormData(
        title: 'Edit ${priorityTwist.name}',
        groups: [
          StaticFormGroup(
            items: [
              FormTextInput(
                key: 'name',
                label: 'Name',
                initialValue: priorityTwist.name,
                required: true,
              ),
              FormInfo(
                key: 'integrations',
                divider: false,
                builder: (context) => TwistIntegrationsWidget(
                  priorityTwistId: priorityTwist.id.toString(),
                  initialData: integrations,
                  refreshNotifier: refreshNotifier,
                  onChanged: (changes) {
                    integrationChanges = changes;
                  },
                ),
              ),
              if (integrations.providers.isNotEmpty)
                FormButton(
                  key: 'add_account',
                  buildCommand: (_) => ShowAddIntegrationAccount(
                    priorityTwistId: priorityTwist.id.toString(),
                    onAccountAdded: () => refreshNotifier.value++,
                  ),
                ),
              FormDivider(key: 'divider'),
              FormButton(
                key: 'save',
                buildCommand: (values) {
                  final name = values['name'] as String;
                  return SaveTwist(
                    priorityTwist: priorityTwist,
                    name: name,
                    initialEnabled: initialEnabled,
                    changes: integrationChanges,
                  );
                },
              ),
              FormButton(
                key: 'details',
                buildCommand: (_) =>
                    ShowTwistDetails(matchingTwist, priority: loadedPriority),
              ),
              FormButton(
                key: 'archive',
                buildCommand: (_) => PromptToArchiveTwist(priorityTwist),
              ),
            ],
          ),
        ],
      );
    } catch (e, t) {
      log.warning('Error loading twist details', e, t);
      // Fallback to simple form without details
      return FormData(
        title: 'Edit ${priorityTwist.name}',
        groups: [
          StaticFormGroup(
            items: [
              FormTextInput(
                key: 'name',
                label: 'Name',
                initialValue: priorityTwist.name,
                required: true,
              ),
              FormDivider(key: 'divider'),
              FormButton(
                key: 'save',
                buildCommand: (values) {
                  final name = values['name'] as String;
                  return EditTwistName(priorityTwist, name: name);
                },
              ),
              FormButton(
                key: 'archive',
                buildCommand: (_) => PromptToArchiveTwist(priorityTwist),
              ),
            ],
          ),
        ],
      );
    }
  }
}

// ============================================================================
// Show Twist Info (details only) + Setup Twist (add flow)
// ============================================================================

class ShowTwistDetails extends ShowForm {
  ShowTwistDetails(this.twist, {this.priority})
    : super(
        title: 'View twist details',
        icon: PlotIcon.twist,
        form: (context) => _buildForm(twist, priority),
      );

  final Twist twist;
  final Priority? priority;

  static Future<FormData> _buildForm(Twist twist, Priority? priority) async {
    return FormData(
      title: twist.name,
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'details',
              divider: false,
              builder: (context) =>
                  TwistDetails(twist: twist, priority: priority),
            ),
          ],
        ),
      ],
    );
  }
}

/// Shows twist details (description, author, permissions) with an "Add Twist" button.
class ShowTwistInfo extends ShowForm {
  ShowTwistInfo(this.twist, {Priority? defaultPriority})
    : super(
        title: _formatTwistName(twist.name, twist.environment),
        subtitle: twist.description,
        icon: PlotIcon.twist,
        form: (context) => _buildForm(context, twist, defaultPriority),
      );

  final Twist twist;

  static Future<FormData> _buildForm(
    BuildContext context,
    Twist twist,
    Priority? defaultPriority,
  ) async {
    return FormData(
      title: twist.name,
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              divider: true,
              builder: (context) => TwistDetails(twist: twist),
            ),
            FormButton(
              key: 'add',
              buildCommand: (_) =>
                  SetupTwist(twist, defaultPriority: defaultPriority),
            ),
          ],
        ),
      ],
    );
  }

  /// Formats twist name with environment label if not public
  static String _formatTwistName(String name, String environment) {
    if (environment == 'public') {
      return name;
    }
    final envLabel = environment[0].toUpperCase() + environment.substring(1);
    return '$name ($envLabel)';
  }
}

// ============================================================================
// Setup Twist (add flow with draft)
// ============================================================================

/// Opens the setup modal with priority selector, name, integrations, and syncables.
/// Creates a draft twist for the auth flow, then activates it on submit.
class SetupTwist extends ShowForm {
  SetupTwist(this.twist, {this.defaultPriority})
    : super(
        title: 'Add Twist',
        icon: PlotIcon.add,
        form: (context) => _buildForm(context, twist, defaultPriority),
      );

  final Twist twist;
  final Priority? defaultPriority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Create draft before opening form
    String? draftId;
    try {
      draftId = await TwistApi.createDraft(
        twistId: twist.id,
        twistEnvironment: twist.environment,
        name: twist.name,
      );
    } catch (e, t) {
      log.warning('Failed to create draft twist', e, t);
      return CommandMessage(
        'Failed to set up twist. Please try again.',
        isError: true,
      );
    }

    // Store draftId for the form builder via a static variable
    _currentDraftId = draftId;

    final result = await super.run(context);

    // If the form was dismissed without activation, delete the draft
    if (_currentDraftId != null) {
      try {
        await TwistApi.deleteDraft(draftId);
      } catch (e, t) {
        log.warning('Failed to delete draft twist', e, t);
      }
      _currentDraftId = null;
    }

    return result;
  }

  /// Current draft ID, set before opening the form.
  static String? _currentDraftId;

  /// Called by ActivateDraftCommand to clear the draft ID after successful activation.
  static void clearDraft() {
    _currentDraftId = null;
  }

  static bool _isUnderPlot(Priority priority, Priority plotPriority) {
    return priority.id == plotPriority.id ||
        plotPriority.path.isParent(priority.path);
  }

  static Future<FormData> _buildForm(
    BuildContext context,
    Twist twist,
    Priority? defaultPriority,
  ) async {
    final draftId = _currentDraftId;
    if (draftId == null) {
      return FormData(
        title: twist.name,
        groups: [
          StaticFormGroup(
            items: [
              FormInfo(key: 'error', text: 'Failed to create draft twist.'),
            ],
          ),
        ],
      );
    }

    // Get default priority from context
    final nowBloc = context.read<NowBloc>();
    final currentPriority = nowBloc.state is NowLoaded
        ? (nowBloc.state as NowLoaded).priority
        : null;
    var initialPriority =
        defaultPriority ?? currentPriority ?? await Priority.getDefault();

    // Don't default to @plot or its descendants
    final allPriorities = await Priority.get(order: PriorityOrder.nested);
    final plotPriority = allPriorities.firstWhereOrNull(
      (p) => p.key == '@plot',
    );
    if (plotPriority != null && _isUnderPlot(initialPriority, plotPriority)) {
      initialPriority = await Priority.getDefault();
    }

    // Pre-fetch integrations for the draft
    final integrations = await TwistApi.getIntegrations(draftId);
    final refreshNotifier = ValueNotifier<int>(0);

    // Track integration changes from the integrations widget
    var integrationChanges = const IntegrationChanges();

    return FormData(
      title: 'Set up ${twist.name}',
      groups: [
        StaticFormGroup(
          items: [
            FormSelect<Priority>(
              key: 'priority',
              label: 'Add to Priority',
              initialValue: initialPriority,
              items: (search) async {
                final priorities = await Priority.get(
                  order: PriorityOrder.nested,
                  search: search,
                );
                final plot = priorities.firstWhereOrNull(
                  (p) => p.key == '@plot',
                );
                if (plot == null) return priorities;
                return priorities.where((p) => !_isUnderPlot(p, plot)).toList();
              },
              labelBuilder: (p) => PriorityLabel(priority: p),
              titleBuilder: (p) => p.ancestorsLabel() != null
                  ? '${p.ancestorsLabel()}${Priority.separator}${p.title}'
                  : p.title,
            ),
            FormTextInput(
              key: 'name',
              label: 'Name',
              initialValue: twist.name,
              required: true,
            ),
            FormInfo(
              key: 'integrations',
              divider: false,
              builder: (context) => TwistIntegrationsWidget(
                priorityTwistId: draftId,
                setupMode: true,
                initialData: integrations,
                refreshNotifier: refreshNotifier,
                onChanged: (changes) {
                  integrationChanges = changes;
                },
              ),
            ),
            if (integrations.providers.isNotEmpty)
              FormButton(
                key: 'add_account',
                buildCommand: (_) => ShowAddIntegrationAccount(
                  priorityTwistId: draftId,
                  onAccountAdded: () => refreshNotifier.value++,
                ),
              ),
            FormDivider(key: 'divider'),
            FormButton(
              key: 'add',
              buildCommand: (values) {
                final selectedPriority = values['priority'] as Priority;
                final name = values['name'] as String;
                // Convert IntegrationChanges to SelectedSyncable list
                final selectedSyncables = integrationChanges.selectedSyncables
                    .map((key) {
                      final parts = key.split(':');
                      return SelectedSyncable(
                        provider: parts[0],
                        syncableId: parts.sublist(1).join(':'),
                      );
                    })
                    .toList();
                return ActivateTwist(
                  draftId: draftId,
                  priority: selectedPriority,
                  name: name,
                  syncables: selectedSyncables,
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// Activates a draft twist: assigns priority, calls activate, enables syncables.
class ActivateTwist extends Command {
  ActivateTwist({
    required this.draftId,
    required this.priority,
    required this.name,
    required this.syncables,
  }) : super(
         title: 'Activate Twist',
         icon: PlotIcon.twist,
         eventObject: EventObject.twist,
         eventAction: EventAction.added,
       );

  final String draftId;
  final Priority priority;
  final String name;
  final List<SelectedSyncable> syncables;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await TwistApi.activateDraft(
        draftId: draftId,
        priorityId: priority.id.toString(),
        name: name,
        syncables: syncables.isNotEmpty
            ? syncables
                  .map(
                    (s) => {
                      'provider': s.provider,
                      'syncableId': s.syncableId,
                    },
                  )
                  .toList()
            : null,
      );

      // Mark the draft as activated so cleanup doesn't delete it
      SetupTwist.clearDraft();

      // Sync new twist to local DB
      await PriorityTwist.pull();

      // Pop all modals and reopen ManageTwists
      if (context.mounted) {
        Modal.popAll(context);
        // Schedule ManageTwists to open after the modal stack clears
        Future.microtask(() {
          if (context.mounted) {
            ManageTwists().run(context);
          }
        });
      }

      return const CommandDone();
    } catch (e, t) {
      log.warning('Failed to activate twist', e, t);
      return CommandMessage(
        'Failed to add twist. Please try again.',
        isError: true,
      );
    }
  }
}

// ============================================================================
// Add Integration Account (sub-modal)
// ============================================================================

/// Shows branded auth buttons for available providers.
/// When a provider is authenticated, pops back and refreshes integrations.
class ShowAddIntegrationAccount extends ShowForm {
  ShowAddIntegrationAccount({
    required String priorityTwistId,
    required VoidCallback onAccountAdded,
  }) : super(
         title: 'Add account',
         icon: PlotIcon.add,
         form: (context) => _buildForm(priorityTwistId, onAccountAdded),
       );

  static Future<FormData> _buildForm(
    String priorityTwistId,
    VoidCallback onAccountAdded,
  ) async {
    final integrations = await TwistApi.getIntegrations(priorityTwistId);
    return FormData(
      title: 'Add account',
      groups: [
        StaticFormGroup(
          items: integrations.providers
              .map(
                (provider) => FormInfo(
                  key: 'auth_${provider.provider.name}',
                  divider: false,
                  builder: (formContext) => Padding(
                    padding: widgetPadding.copyWith(top: 0),
                    child: _IntegrationAuthButton(
                      provider: provider,
                      hasExistingAccount: integrations.accounts.any(
                        (a) => a.provider == provider.provider,
                      ),
                      priorityTwistId: priorityTwistId,
                      onSuccess: () {
                        onAccountAdded();
                        if (formContext.mounted) {
                          Modal.pop<CommandReturn>(
                            formContext,
                            Value(const CommandSkipped()),
                          );
                        }
                      },
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class _IntegrationAuthButton extends StatefulWidget {
  const _IntegrationAuthButton({
    required this.provider,
    required this.hasExistingAccount,
    required this.priorityTwistId,
    required this.onSuccess,
  });

  final TwistProvider provider;
  final bool hasExistingAccount;
  final String priorityTwistId;
  final VoidCallback onSuccess;

  @override
  State<_IntegrationAuthButton> createState() => _IntegrationAuthButtonState();
}

class _IntegrationAuthButtonState extends State<_IntegrationAuthButton> {
  bool _isLoading = false;

  /// Whether native Google Sign-In is supported on this platform.
  bool get _useNativeGoogleSignIn =>
      !kIsWeb &&
      widget.provider.provider == AuthProvider.google &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.android);

  Future<void> _startAuth() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    final redirectUri = kIsWeb
        ? Env.webAuthCallbackUrl
        : 'plotday://auth/callback';

    String? platform;
    if (!kIsWeb) {
      if (defaultTargetPlatform == TargetPlatform.android) {
        platform = 'android';
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        platform = 'ios';
      } else {
        platform = 'desktop';
      }
    }

    try {
      // Create the server-side callback for this auth flow
      final authUrl = await TwistApi.getAuthUrl(
        priorityTwistId: widget.priorityTwistId,
        provider: widget.provider.provider.name,
        redirectUri: redirectUri,
        platform: platform,
      );

      if (_useNativeGoogleSignIn) {
        await _startNativeGoogleAuth(authUrl);
      } else {
        await _startBrowserAuth(authUrl, redirectUri);
      }

      widget.onSuccess();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        log.info('Google sign-in cancelled');
        return;
      }
      log.warning('OAuth flow failed', e);
      if (mounted) _showAuthError();
    } catch (e, t) {
      log.warning('OAuth flow failed', e, t);
      if (mounted) _showAuthError();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Use native Google Sign-In SDK on macOS/iOS/Android.
  Future<void> _startNativeGoogleAuth(TwistAuthUrl authUrl) async {
    final scopes = widget.provider.scopes;

    await GoogleSignIn.instance.signOut();
    final account = await GoogleSignIn.instance.authenticate(
      scopeHint: scopes,
    );

    final serverAuth = await account.authorizationClient.authorizeServer(
      scopes,
    );
    final code = serverAuth?.serverAuthCode;
    if (code == null) {
      throw Exception('No server auth code received from Google');
    }

    final callbackUri = Uri(
      path: '/auth',
      queryParameters: {
        'code': code,
        'clientId': Env.googleClientId,
        'redirectUri': Env.authServerCallbackUrl,
        'provider': 'google',
        'scopes': scopes.join(','),
        'callback': authUrl.callback,
      },
    );
    await api.post<Map<String, dynamic>>(callbackUri.toString());
  }

  /// Use FlutterWebAuth2 browser-based OAuth flow.
  Future<void> _startBrowserAuth(
    TwistAuthUrl authUrl,
    String redirectUri,
  ) async {
    final result = await FlutterWebAuth2.authenticate(
      url: authUrl.url,
      callbackUrlScheme: redirectUri.split(':').first,
    );

    final responseUri = Uri.parse(result);
    final params = responseUri.queryParameters;
    final code = params['code'];

    if (code != null) {
      final callbackUri = Uri(
        path: '/auth',
        queryParameters: {
          'code': code,
          'clientId': authUrl.clientId,
          'redirectUri': redirectUri,
          'state': authUrl.state,
        },
      );
      await api.post<Map<String, dynamic>>(callbackUri.toString());
    }
  }

  void _showAuthError() {
    final providerName =
        widget.provider.provider.name[0].toUpperCase() +
        widget.provider.provider.name.substring(1);
    context.showToast(
      message: 'Unable to connect with $providerName. Please try again.',
      isError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = getAuthProviderConfig(widget.provider.provider);
    final providerName =
        widget.provider.provider.name[0].toUpperCase() +
        widget.provider.provider.name.substring(1);
    final label = widget.hasExistingAccount
        ? 'Add another $providerName account'
        : config.buttonText;

    return FButton(
      mainAxisSize: .max,
      style: buildAuthButtonStyle(context, config),
      onPress: _isLoading ? null : _startAuth,
      prefix: _isLoading
          ? Spinner(color: config.loadingColor, size: config.iconSize)
          : _buildProviderIcon(widget.provider.provider, config.iconSize),
      child: Text(
        label,
        style: context.theme.typography.base.copyWith(
          fontWeight: config.fontWeight,
          fontFamily: config.fontFamily,
          color: _isLoading ? config.disabledTextColor : config.textColor,
          height: 1,
        ),
      ),
    );
  }

  static Widget _buildProviderIcon(AuthProvider provider, double size) {
    final icon = switch (provider) {
      AuthProvider.google => 'assets/google.svg',
      AuthProvider.microsoft => 'assets/microsoft.svg',
      AuthProvider.slack => 'assets/slack.svg',
      AuthProvider.atlassian => 'assets/atlassian.svg',
      AuthProvider.linear => 'assets/linear.svg',
      AuthProvider.asana => 'assets/asana.svg',
      _ => null,
    };
    if (icon == null) return SizedBox(width: size, height: size);
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: SvgPicture.asset(icon, width: size, height: size),
      ),
    );
  }
}

// ============================================================================
// Edit/Update/Remove commands
// ============================================================================

/// Saves all edit twist changes: name, syncable toggles, and account removals.
class SaveTwist extends Command {
  SaveTwist({
    required this.priorityTwist,
    required this.name,
    required this.initialEnabled,
    required this.changes,
  }) : super(
         title: 'Save',
         icon: FontAwesomeIcons.check,
         eventObject: EventObject.twist,
         eventAction: EventAction.updated,
       );

  final PriorityTwist priorityTwist;
  final String? name;
  final Set<String> initialEnabled;
  final IntegrationChanges changes;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      if (name == null) {
        return CommandMessage('Name is required', isError: true);
      }

      final ptId = priorityTwist.id.toString();

      // 1. Update name
      await TwistApi.updateTwist(priorityTwistId: ptId, name: name!);

      // 2. Compute providers being removed (skip their syncable changes)
      final removedProviders = changes.removedAccounts
          .map((k) => k.split(':').first)
          .toSet();

      // 3. Enable/disable syncables (skip removed providers)
      final toEnable = changes.selectedSyncables.difference(initialEnabled);
      final toDisable = initialEnabled.difference(changes.selectedSyncables);

      for (final key in toEnable) {
        final parts = key.split(':');
        final provider = parts[0];
        if (removedProviders.contains(provider)) continue;
        final syncableId = parts.sublist(1).join(':');
        await TwistApi.enableSyncable(
          priorityTwistId: ptId,
          provider: provider,
          syncableId: syncableId,
        );
      }

      for (final key in toDisable) {
        final parts = key.split(':');
        final provider = parts[0];
        if (removedProviders.contains(provider)) continue;
        final syncableId = parts.sublist(1).join(':');
        await TwistApi.disableSyncable(
          priorityTwistId: ptId,
          provider: provider,
          syncableId: syncableId,
        );
      }

      // 4. Remove accounts
      for (final accountKey in changes.removedAccounts) {
        final parts = accountKey.split(':');
        final provider = parts[0];
        final actorId = parts.sublist(1).join(':');
        await TwistApi.removeIntegration(
          priorityTwistId: ptId,
          provider: provider,
          actorId: actorId,
        );
      }

      return CommandMessage('Twist "${name!}" saved');
    } catch (e, t) {
      log.warning('Failed to save twist', e, t);
      return CommandMessage('Failed to save twist', isError: true);
    }
  }
}

class EditTwistName extends Command {
  EditTwistName(this.priorityTwist, {this.name})
    : super(
        title: 'Save',
        icon: FontAwesomeIcons.check,
        eventObject: EventObject.twist,
        eventAction: EventAction.updated,
      );

  final PriorityTwist priorityTwist;
  final String? name;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      if (name == null) {
        return CommandMessage('Name is required', isError: true);
      }

      await TwistApi.updateTwist(
        priorityTwistId: priorityTwist.id.toString(),
        name: name!,
      );

      return CommandMessage('Twist name changed to "${name!}"');
    } catch (e, t) {
      log.warning('Failed to update twist name', e, t);
      return CommandMessage('Failed to update twist name', isError: true);
    }
  }
}

class RemoveTwist extends Command {
  RemoveTwist(this.twist)
    : super(
        title: 'Remove Twist',
        subtitle: 'Remove ${twist.name} from this priority',
        eventObject: EventObject.twist,
        eventAction: EventAction.archived,
        icon: FontAwesomeIcons.trash,
      );

  final PriorityTwist twist;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await TwistApi.removeTwist(twist.id.toString());

      return CommandMessage('Twist "${twist.name}" removed successfully');
    } catch (e, t) {
      log.warning('Failed to remove twist', e, t);
      return CommandMessage('Failed to remove twist', isError: true);
    }
  }
}

class PromptToArchiveTwist extends ShowForm {
  PromptToArchiveTwist(this.twist)
    : super(
        title: 'Archive',
        icon: PlotIcon.archived,
        form: (context) => _buildForm(context, twist),
      );

  final PriorityTwist twist;

  static Future<FormData> _buildForm(
    BuildContext context,
    PriorityTwist twist,
  ) async {
    return FormData(
      title: 'Archive Twist',
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              text:
                  'Archiving this twist will remove it and archive the activities it has created.',
            ),
            FormDivider(key: 'divider'),
            FormButton(
              key: 'archive',
              buildCommand: (_) => ArchiveTwist(twist),
            ),
          ],
        ),
      ],
    );
  }
}

class ArchiveTwist extends Command {
  ArchiveTwist(this.twist)
    : super(
        title: 'Archive Twist',
        icon: PlotIcon.archived,
        eventObject: EventObject.twist,
        eventAction: EventAction.archived,
      );

  final PriorityTwist twist;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await TwistApi.archiveAndRemoveTwist(twist.id.toString());

      // Update local database to immediately reflect the archive
      await Store.get.save(
        PriorityTwist.table,
        twist.copyWith(
          archivedAt: Value(DateTime.now()),
          updatedAt: DateTime.now(),
        ),
        PriorityTwistsBase(),
      );

      return CommandMessage(
        'Twist "${twist.name}" and its activities archived successfully',
      );
    } catch (e, t) {
      log.warning('Failed to archive twist', e, t);
      return CommandMessage('Failed to archive twist', isError: true);
    }
  }
}

class ArchiveActivitiesCreatedByTwist extends ShowForm {
  ArchiveActivitiesCreatedByTwist(this.twist)
    : super(
        title: 'Archive Activities',
        icon: PlotIcon.archived,
        form: (context) => _buildForm(context, twist),
      );

  final PriorityTwist twist;

  static Future<FormData> _buildForm(
    BuildContext context,
    PriorityTwist twist,
  ) async {
    // Query the count of activities created by this twist
    final count = await _getActivityCount(twist.id);

    return FormData(
      title: 'Archive Activities Created by Twist',
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              text: count == 0
                  ? 'No activities were created by this twist.'
                  : count == 1
                  ? '1 activity was created by this twist and will be archived.'
                  : '$count activities were created by this twist and will be archived.',
            ),
            if (count > 0)
              FormButton(
                key: 'archive',
                buildCommand: (_) => _ArchiveActivitiesCommand(twist, count),
              ),
          ],
        ),
      ],
    );
  }

  static Future<int> _getActivityCount(Uuid priorityTwistId) async {
    try {
      final authorId = ActorId(priorityTwistId);
      final query = Store.get.select(Store.get.activities)
        ..where((a) => a.authorId.equalsValue(authorId))
        ..where((a) => a.archivedAt.isNull());
      final result = await query.get();
      return result.length;
    } catch (e, t) {
      log.warning('Failed to count activities', e, t);
      return 0;
    }
  }
}

class _ArchiveActivitiesCommand extends Command {
  _ArchiveActivitiesCommand(this.twist, this.count)
    : super(
        title: 'Archive Activities',
        icon: PlotIcon.archived,
        eventObject: EventObject.activity,
        eventAction: EventAction.archived,
      );

  final PriorityTwist twist;
  final int count;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final authorId = ActorId(twist.id);
      final now = DateTime.now();
      await (Store.get.update(Store.get.activities)
            ..where((a) => a.authorId.equalsValue(authorId))
            ..where((a) => a.archivedAt.isNull()))
          .write(ActivitiesCompanion(archivedAt: Value(now)));

      // Trigger sync to push archived changes to server
      Activity.push();

      return CommandMessage(
        count == 1 ? '1 activity archived' : '$count activities archived',
      );
    } catch (e, t) {
      log.warning('Failed to archive activities', e, t);
      return CommandMessage('Failed to archive activities', isError: true);
    }
  }
}
