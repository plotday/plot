import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:intl/intl.dart';

import 'package:plot/api/twist_api.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/spacing.dart';
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
            padding: EdgeInsets.only(
              top: theme.spacing.lg,
              bottom: theme.spacing.sm,
            ),
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
              padding: EdgeInsets.only(
                left: theme.spacing.sm,
                bottom: theme.spacing.sm,
              ),
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
      mainAxisSize: MainAxisSize.min,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: theme.spacing.sm),
            // Metadata section
            if (twist.description != null) ...[
              Padding(
                padding: theme.spacing.padding.copyWith(top: 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      twist.description!,
                      style: TextStyle(
                        fontSize: theme.typography.base.fontSize,
                        // color: theme.colors.mutedForeground,
                      ),
                    ),
                    SizedBox(height: theme.spacing.md),
                    if (priority != null) ...[
                      _buildPriorityRow(context, priority!),
                      SizedBox(height: theme.spacing.sm),
                    ],
                    _buildMetadataRow(context, 'Author', authorText),
                    if (twist.environment != 'public') ...[
                      SizedBox(height: theme.spacing.sm),
                      _buildMetadataRow(
                        context,
                        'Publishing Status',
                        twist.environment.capitalize(),
                      ),
                    ],
                    if (twist.permissions?.forDomain('ai') != null) ...[
                      SizedBox(height: theme.spacing.sm),
                      _buildMetadataRow(
                        context,
                        'AI',
                        twist.aiRequired ? 'Required' : 'Optional',
                      ),
                    ],
                    if (twist.createdAt != null) ...[
                      SizedBox(height: theme.spacing.sm),
                      _buildMetadataRow(
                        context,
                        'First Published',
                        dateFormat.format(twist.createdAt!),
                      ),
                    ],
                    if (twist.updatedAt != null) ...[
                      SizedBox(height: theme.spacing.sm),
                      _buildMetadataRow(
                        context,
                        'Last Updated',
                        dateFormat.format(twist.updatedAt!),
                      ),
                    ],
                  ],
                ),
              ),
            ],

            // Divider
            Container(height: 1, color: theme.colors.border),

            // Permissions section
            Padding(
              padding: theme.spacing.padding.copyWith(bottom: 0),
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
            SizedBox(height: theme.spacing.sm),
          ],
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
