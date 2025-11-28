import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_editor.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/command/command.dart';
import 'package:plot/page/priority.dart'
    show ActivityPanelControllerProvider, PriorityShortcutsProviderState;

@RoutePage()
class NewActivityPage extends StatefulWidget {
  const NewActivityPage({super.key});

  @override
  State<NewActivityPage> createState() => _NewActivityPageState();
}

class _NewActivityPageState extends State<NewActivityPage> {
  final GlobalKey<ActivityEditorState> _activityEditorKey =
      GlobalKey<ActivityEditorState>();

  // Save reference to provider to avoid looking it up in dispose()
  PriorityShortcutsProviderState? _provider;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Save the provider reference
    _provider = ActivityPanelControllerProvider.maybeOf(context);
    // Register ActivityEditor with the focus coordination provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _provider?.registerActivityPanel(
        editorFocusCallback: () => _activityEditorKey.currentState?.focus(),
      );
    });
  }

  @override
  void dispose() {
    // Unregister from the focus coordination provider using saved reference
    _provider?.unregisterActivityPanel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        return BlocBuilder<PriorityBloc, PriorityState>(
          builder: (context, state) {
            return PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, result) {
                if (!didPop && !layoutState.multiPanel) {
                  context.run(ChangeCurrentActivity(null));
                }
              },
              child: Scaffold(
                translucent: true,
                scrollable: false,
                header: layoutState.middlePanelVisible || !layoutState.multiPanel
                    ? null
                    : Header(
                        title: 'New Activity',
                        prefixCommands: [
                          CommandWrapper(
                            ChangeCurrentActivity(null),
                            icon: Value(PlotIcon.back),
                          ),
                        ],
                      ),
                body: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: ActivityEditor(
                        key: _activityEditorKey,
                        draft: state.draft,
                        expand: false,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
