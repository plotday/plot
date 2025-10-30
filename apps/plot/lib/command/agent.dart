import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'command.dart';
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

class ManageAgents extends ShowCommands {
  ManageAgents(Priority priority)
    : super(
        title: 'Manage Agents',
        icon: PlotIcon.agent,
        commands: (context) => _getAgentCommands(priority),
      );

  static Future<Commands> _getAgentCommands(Priority priority) async {
    final results = await Future.wait([
      AgentApi.getAgentsForPriority(priority),
      AgentApi.getAllAgents(priority),
    ]);

    final priorityAgents = results[0] as List<PriorityAgent>;
    final allAgents = results[1] as List<Agent>;

    final editCommands = priorityAgents
        .map((agent) => EditAgentCommand(priority, agent))
        .toList();

    final viewCommands = allAgents
        .map(
          (agent) =>
              ViewAgentDetailsCommand(priority, agent, isInstalled: false),
        )
        .toList();

    return Commands(
      groups: [
        StaticCommandGroup(title: 'Active Agents', commands: editCommands),
        StaticCommandGroup(title: 'Available Agents', commands: viewCommands),
      ],
    );
  }
}

class ViewAgentDetailsCommand extends ShowCommands {
  ViewAgentDetailsCommand(
    this.priority,
    this.agent, {
    required this.isInstalled,
    this.priorityAgent,
  }) : super(
         title: _formatAgentName(agent.name, agent.environment),
         icon: PlotIcon.agent,
         commands: (context) =>
             _getDetailCommands(priority, agent, isInstalled, priorityAgent),
       );

  final Priority priority;
  final Agent agent;
  final bool isInstalled;
  final PriorityAgent? priorityAgent;

  static Future<Commands> _getDetailCommands(
    Priority priority,
    Agent agent,
    bool isInstalled,
    PriorityAgent? priorityAgent,
  ) async {
    final commands = <Command>[];

    if (isInstalled && priorityAgent != null) {
      commands.add(RemoveAgent(priorityAgent));
    } else {
      commands.add(AddAgent(priority, agent));
    }

    return Commands(
      groups: [
        StaticCommandGroup(
          infoBuilder: (context) => AgentDetails(agent: agent),
          commands: commands,
        ),
      ],
    );
  }
}

class EditAgentCommand extends ShowCommands {
  EditAgentCommand(this.priority, this.priorityAgent)
    : super(
        title: _formatAgentName(
          priorityAgent.name,
          priorityAgent.agentEnvironment,
        ),
        icon: PlotIcon.settings,
        commands: (context) => _getAgentCommands(priority, priorityAgent),
      );

  final Priority priority;
  final PriorityAgent priorityAgent;

  static Future<Commands> _getAgentCommands(
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

      return Commands(
        groups: [
          StaticCommandGroup(
            infoBuilder: (context) => AgentDetails(agent: matchingAgent),
            commands: [RemoveAgent(priorityAgent)],
          ),
        ],
      );
    } catch (e, t) {
      log.warning('Error loading agent details', e, t);
      // Fallback to simple commands without details
      return Commands(
        groups: [
          StaticCommandGroup(
            title: 'Agent Actions',
            commands: [RemoveAgent(priorityAgent)],
          ),
        ],
      );
    }
  }
}

class AddAgent extends Command {
  AddAgent(this.priority, this.agent)
    : super(
        title: 'Add ${_formatAgentName(agent.name, agent.environment)}',
        subtitle: agent.description ?? 'Add this agent to priority',
        icon: PlotIcon.agent,
      );

  final Priority priority;
  final Agent agent;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await AgentApi.addAgent(
        priorityId: priority.id.toString(),
        agentId: agent.id,
        agentEnvironment: agent.environment,
      );
      Posthog().capture(eventName: 'Agent Added');

      // Reload agents in PriorityBloc
      if (context.mounted) {
        await context.read<PriorityBloc>().reloadAgents();
      }

      return CommandMessage(
        'Agent "${_formatAgentName(agent.name, agent.environment)}" added successfully',
      );
    } catch (e, t) {
      log.warning('Failed to add agent', e, t);
      return CommandMessage(
        'Failed to add agent: ${e.toString()}',
        isError: true,
      );
    }
  }
}

class RemoveAgent extends Command {
  RemoveAgent(this.agent)
    : super(
        title: 'Remove Agent',
        subtitle:
            'Remove ${_formatAgentName(agent.name, agent.agentEnvironment)} from this priority',
        icon: FontAwesomeIcons.trash,
      );

  final PriorityAgent agent;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await AgentApi.removeAgent(agent.id);
      Posthog().capture(eventName: 'Agent Removed');

      // Reload agents in PriorityBloc
      if (context.mounted) {
        await context.read<PriorityBloc>().reloadAgents();
      }

      return CommandMessage(
        'Agent "${_formatAgentName(agent.name, agent.agentEnvironment)}" removed successfully',
      );
    } catch (e) {
      return CommandMessage(
        'Failed to remove agent: ${e.toString()}',
        isError: true,
      );
    }
  }
}
