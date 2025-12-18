import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:intl/intl.dart';

import 'package:plot/api/twist_api.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/layout.dart';
import 'package:plot/util/string.dart';
import 'package:plot/widget/twist_permission_helper.dart';

class TwistDetails extends StatelessWidget {
  const TwistDetails({required this.twist, this.priority, super.key});

  final Twist twist;
  final Priority? priority;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final dateFormat = DateFormat.yMMMd();

    // Build author section
    final String authorText;
    if (twist.environment == 'personal') {
      authorText = 'You';
    } else if (twist.authorName != null) {
      authorText = twist.authorName!;
    } else {
      authorText = 'Unknown';
    }

    // Build permissions section
    final permissionsList = <Widget>[];
    if (twist.permissions != null) {
      final descriptions = PermissionDescriptions.fromTwistPermissions(
        twist.permissions!,
      );

      descriptions.categories.forEach((categoryName, descriptionsList) {
        // Add category header
        permissionsList.add(
          Padding(
            key: ValueKey('category_$categoryName'),
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(
              categoryName,
              style: TextStyle(
                fontSize: theme.typography.sm.fontSize,
                fontWeight: FontWeight.w600,
                color: theme.colors.foreground,
              ),
            ),
          ),
        );

        // Add bullet points for each description
        for (final description in descriptionsList) {
          permissionsList.add(
            Padding(
              key: ValueKey('${categoryName}_$description'),
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '• ',
                    style: TextStyle(
                      fontSize: theme.typography.base.fontSize,
                      color: theme.colors.foreground,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      description,
                      style: TextStyle(
                        fontSize: theme.typography.base.fontSize,
                        color: theme.colors.foreground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
      });
    }

    if (permissionsList.isEmpty) {
      permissionsList.add(
        Text(
          'No permissions required',
          style: TextStyle(
            fontSize: theme.typography.base.fontSize,
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
        if (twist.description != null) ...[
          Padding(
            padding: widgetPadding.copyWith(top: 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(
                  twist.description!,
                  style: TextStyle(
                    fontSize: theme.typography.base.fontSize,
                    color: theme.colors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),

          // Divider
          Container(height: 1, color: theme.colors.border),
        ],

        // Metadata section
        Padding(
          padding: widgetPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (priority != null) ...[
                _buildPriorityRow(context, priority!),
                const SizedBox(height: 4),
              ],
              _buildMetadataRow(context, 'Author', authorText),
              if (twist.environment != 'public') ...[
                const SizedBox(height: 4),
                _buildMetadataRow(
                  context,
                  'Publishing Status',
                  twist.environment.capitalize(),
                ),
              ],
              if (twist.createdAt != null) ...[
                const SizedBox(height: 4),
                _buildMetadataRow(
                  context,
                  'First Published',
                  dateFormat.format(twist.createdAt!),
                ),
              ],
              if (twist.updatedAt != null) ...[
                const SizedBox(height: 4),
                _buildMetadataRow(
                  context,
                  'Last Updated',
                  dateFormat.format(twist.updatedAt!),
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
                  color: theme.colors.mutedForeground,
                ),
              ),
              ...permissionsList,
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPriorityRow(BuildContext context, Priority priority) {
    final theme = context.theme;
    final priorityPath = priority.ancestorsLabel() != null
        ? '${priority.ancestorsLabel()}${Priority.separator}${priority.title}'
        : priority.title;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Installed in',
          style: TextStyle(
            fontSize: theme.typography.base.fontSize,
            color: theme.colors.mutedForeground,
          ),
        ),
        Flexible(
          child: Text(
            priorityPath,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: theme.typography.base.fontSize,
              color: theme.colors.foreground,
            ),
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
            fontSize: theme.typography.base.fontSize,
            color: theme.colors.mutedForeground,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: theme.typography.base.fontSize,
            color: theme.colors.foreground,
          ),
        ),
      ],
    );
  }
}
