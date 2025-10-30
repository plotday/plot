import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:intl/intl.dart';

import 'package:plot/api/agent_api.dart';
import 'package:plot/widget/theme.dart';

class AgentDetails extends StatelessWidget {
  const AgentDetails({required this.agent, super.key});

  final Agent agent;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final dateFormat = DateFormat.yMMMd();

    // Build author section
    final String authorText;
    if (agent.environment == 'personal') {
      authorText = 'You';
    } else if (agent.authorName != null) {
      authorText = agent.authorName!;
    } else {
      authorText = 'Unknown';
    }

    // Build permissions section
    final permissionsList = <Widget>[];
    if (agent.permissions != null) {
      final groupedPermissions = agent.permissions!.permissions;
      groupedPermissions.forEach((domain, entities) {
        // Add domain header
        permissionsList.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text(
              domain,
              style: TextStyle(
                fontSize: theme.typography.sm.fontSize,
                fontWeight: FontWeight.w600,
                color: theme.colors.foreground,
              ),
            ),
          ),
        );

        // Add entity permissions
        entities.forEach((entity, flags) {
          final flagsText = flags.map((f) => f.name).join(', ');
          permissionsList.add(
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      entity,
                      style: TextStyle(
                        fontSize: theme.typography.sm.fontSize,
                        color: theme.colors.foreground,
                      ),
                    ),
                  ),
                  Text(
                    flagsText,
                    style: TextStyle(
                      fontSize: theme.typography.xs.fontSize,
                      color: theme.colors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
          );
        });
      });
    }

    if (permissionsList.isEmpty) {
      permissionsList.add(
        Text(
          'No permissions required',
          style: TextStyle(
            fontSize: theme.typography.sm.fontSize,
            color: theme.colors.mutedForeground,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Agent name and description
        Padding(
          padding: widgetPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                agent.name,
                style: TextStyle(
                  fontSize: theme.typography.base.fontSize,
                  fontWeight: FontWeight.w600,
                  color: theme.colors.foreground,
                ),
              ),
              if (agent.description != null) ...[
                const SizedBox(height: 4),
                Text(
                  agent.description!,
                  style: TextStyle(
                    fontSize: theme.typography.sm.fontSize,
                    color: theme.colors.mutedForeground,
                  ),
                ),
              ],
            ],
          ),
        ),

        // Divider
        Container(height: 1, color: theme.colors.border),

        // Metadata section
        Padding(
          padding: widgetPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildMetadataRow(context, 'Author', authorText),
              if (agent.version != null) ...[
                const SizedBox(height: 4),
                _buildMetadataRow(context, 'Version', agent.version!),
              ],
              if (agent.createdAt != null) ...[
                const SizedBox(height: 4),
                _buildMetadataRow(
                  context,
                  'First published',
                  dateFormat.format(agent.createdAt!),
                ),
              ],
              if (agent.updatedAt != null) ...[
                const SizedBox(height: 4),
                _buildMetadataRow(
                  context,
                  'Last updated',
                  dateFormat.format(agent.updatedAt!),
                ),
              ],
            ],
          ),
        ),

        // Divider
        Container(height: 1, color: theme.colors.border),

        // Permissions section
        Padding(
          padding: widgetPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Permissions',
                style: TextStyle(
                  fontSize: theme.typography.sm.fontSize,
                  fontWeight: FontWeight.w600,
                  color: theme.colors.foreground,
                ),
              ),
              ...permissionsList,
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMetadataRow(BuildContext context, String label, String value) {
    final theme = context.theme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: theme.typography.sm.fontSize,
            color: theme.colors.mutedForeground,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: theme.typography.sm.fontSize,
            color: theme.colors.foreground,
          ),
        ),
      ],
    );
  }
}
