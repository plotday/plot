import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'action.dart';
import 'package:plot/analytics/analytics.dart';
import 'package:plot/store/store.dart';
import 'package:plot/api/agent_api.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/agent_details.dart';
import 'logging.dart';

/// Formats agent name with environment label if not public
String _formatAgentName(String name, String environment) {
  if (environment == 'public') {
    return name;
  }
  final envLabel = environment[0].toUpperCase() + environment.substring(1);
  return '$name ($envLabel)';
}

class ManageAgents extends ShowActions {
  ManageAgents(Priority priority)
    : super(
        title: 'Manage Agents',
        icon: PlotIcon.agent,
        actions: (context) => _getAgentActions(priority),
      );

  static Future<Actions> _getAgentActions(Priority priority) async {
    final results = await Future.wait([
      AgentApi.getAgentsForPriority(priority),
      AgentApi.getAllAgents(priority),
    ]);

    final priorityAgents = results[0] as List<PriorityAgent>;
    final allAgents = results[1] as List<Agent>;

    final editActions = priorityAgents
        .map((agent) => EditAgentAction(priority, agent))
        .toList();

    final viewActions = allAgents
        .map(
          (agent) =>
              ViewAgentDetailsAction(priority, agent, isInstalled: false),
        )
        .toList();

    return Actions(
      groups: [
        StaticActionGroup(title: 'Active Agents', actions: editActions),
        StaticActionGroup(title: 'Available Agents', actions: viewActions),
      ],
    );
  }
}

class ViewAgentDetailsAction extends ShowActions {
  ViewAgentDetailsAction(
    this.priority,
    this.agent, {
    required this.isInstalled,
    this.priorityAgent,
  }) : super(
         title: _formatAgentName(agent.name, agent.environment),
         icon: PlotIcon.agent,
         actions: (context) =>
             _getDetailActions(priority, agent, isInstalled, priorityAgent),
       );

  final Priority priority;
  final Agent agent;
  final bool isInstalled;
  final PriorityAgent? priorityAgent;

  static Future<Actions> _getDetailActions(
    Priority priority,
    Agent agent,
    bool isInstalled,
    PriorityAgent? priorityAgent,
  ) async {
    final actions = <Action>[];

    if (isInstalled && priorityAgent != null) {
      actions.add(RemoveAgent(priorityAgent));
    } else {
      actions.add(AddAgent(priority, agent));
    }

    return Actions(
      groups: [
        StaticActionGroup(
          infoBuilder: (context) => AgentDetails(agent: agent),
          actions: actions,
        ),
      ],
    );
  }
}

class EditAgentAction extends ShowActions {
  EditAgentAction(this.priority, this.priorityAgent)
    : super(
        title: _formatAgentName(
          priorityAgent.name,
          priorityAgent.agentEnvironment,
        ),
        icon: PlotIcon.settings,
        actions: (context) => _getAgentActions(priority, priorityAgent),
      );

  final Priority priority;
  final PriorityAgent priorityAgent;

  static Future<Actions> _getAgentActions(
    Priority priority,
    PriorityAgent priorityAgent,
  ) async {
    // Fetch the full Agent data to show details
    try {
      // Fetch all agents to find the matching one
      final allAgents = await AgentApi.getAllAgents(priority);
      final matchingAgent = allAgents.firstWhere(
        (a) =>
            a.id == priorityAgent.agentId &&
            a.environment == priorityAgent.agentEnvironment,
        orElse: () => throw Exception('Agent not found'),
      );

      return Actions(
        groups: [
          StaticActionGroup(
            infoBuilder: (context) => AgentDetails(agent: matchingAgent),
            actions: [RemoveAgent(priorityAgent)],
          ),
        ],
      );
    } catch (e, t) {
      log.warning('Error loading agent details', e, t);
      // Fallback to simple actions without details
      return Actions(
        groups: [
          StaticActionGroup(
            title: 'Agent Actions',
            actions: [RemoveAgent(priorityAgent)],
          ),
        ],
      );
    }
  }
}

class AddAgent extends Action {
  AddAgent(this.priority, this.agent)
    : super(
        title: 'Add ${_formatAgentName(agent.name, agent.environment)}',
        subtitle: agent.description ?? 'Add this agent to priority',
        eventObject: EventObject.agent,
        eventAction: EventAction.added,
        icon: PlotIcon.agent,
      );

  final Priority priority;
  final Agent agent;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    try {
      await AgentApi.addAgent(
        priorityId: priority.id.toString(),
        agentId: agent.id,
        agentEnvironment: agent.environment,
      );

      // Reload agents in PriorityBloc
      if (context.mounted) {
        await context.read<PriorityBloc>().reloadAgents();
      }

      return ActionMessage(
        'Agent "${_formatAgentName(agent.name, agent.environment)}" added successfully',
      );
    } catch (e, t) {
      log.warning('Failed to add agent', e, t);
      return ActionMessage(
        'Failed to add agent: ${e.toString()}',
        isError: true,
      );
    }
  }
}

class RemoveAgent extends Action {
  RemoveAgent(this.agent)
    : super(
        title: 'Remove Agent',
        subtitle:
            'Remove ${_formatAgentName(agent.name, agent.agentEnvironment)} from this priority',
        eventObject: EventObject.agent,
        eventAction: EventAction.archived,
        icon: FontAwesomeIcons.trash,
      );

  final PriorityAgent agent;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    try {
      await AgentApi.removeAgent(agent.id);

      // Reload agents in PriorityBloc
      if (context.mounted) {
        await context.read<PriorityBloc>().reloadAgents();
      }

      return ActionMessage(
        'Agent "${_formatAgentName(agent.name, agent.agentEnvironment)}" removed successfully',
      );
    } catch (e) {
      return ActionMessage(
        'Failed to remove agent: ${e.toString()}',
        isError: true,
      );
    }
  }
}
