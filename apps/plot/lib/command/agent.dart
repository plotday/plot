import 'package:flutter/widgets.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/api/agent_api.dart';
import 'package:plot/widget/widget.dart';
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
        .map((agent) => EditAgentCommand(agent))
        .toList();

    final addCommands = allAgents
        .map((agent) => AddAgent(priority, agent))
        .toList();

    return Commands(
      groups: [
        StaticCommandGroup(title: 'Active Agents', commands: editCommands),
        StaticCommandGroup(title: 'Add Agent', commands: addCommands),
      ],
    );
  }
}

class EditAgentCommand extends ShowCommands {
  EditAgentCommand(PriorityAgent agent)
    : super(
        title: _formatAgentName(agent.name, agent.agentEnvironment),
        icon: PlotIcon.settings,
        commands: (context) => _getAgentCommands(agent),
      );

  static Future<Commands> _getAgentCommands(PriorityAgent agent) async {
    return Commands(
      groups: [
        StaticCommandGroup(
          title: 'Agent Actions', 
          commands: [RemoveAgent(agent)]
        ),
      ],
    );
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
      return CommandMessage('Agent "${_formatAgentName(agent.name, agent.environment)}" added successfully');
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
        subtitle: 'Remove ${_formatAgentName(agent.name, agent.agentEnvironment)} from this priority',
        icon: FontAwesomeIcons.trash,
      );

  final PriorityAgent agent;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await AgentApi.removeAgent(agent.id);
      Posthog().capture(eventName: 'Agent Removed');
      return CommandMessage('Agent "${_formatAgentName(agent.name, agent.agentEnvironment)}" removed successfully');
    } catch (e) {
      return CommandMessage(
        'Failed to remove agent: ${e.toString()}',
        isError: true,
      );
    }
  }
}

