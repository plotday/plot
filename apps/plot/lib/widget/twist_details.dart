import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:intl/intl.dart';

import 'package:plot/api/twist_api.dart';
import 'package:plot/widget/theme.dart';

class TwistDetails extends StatelessWidget {
  const TwistDetails({required this.twist, super.key});

  final Twist twist;

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
      final groupedPermissions = twist.permissions!.permissions;
      groupedPermissions.forEach((domain, entities) {
        // Add domain header
        permissionsList.add(
          Padding(
            key: ValueKey('domain_$domain'),
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
              key: ValueKey('${domain}_$entity'),
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
                twist.name,
                style: TextStyle(
                  fontSize: theme.typography.base.fontSize,
                  fontWeight: FontWeight.w600,
                  color: theme.colors.foreground,
                ),
              ),
              if (twist.description != null) ...[
                const SizedBox(height: 4),
                Text(
                  twist.description!,
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
              if (twist.version != null) ...[
                const SizedBox(height: 4),
                _buildMetadataRow(context, 'Version', twist.version!),
              ],
              if (twist.createdAt != null) ...[
                const SizedBox(height: 4),
                _buildMetadataRow(
                  context,
                  'First published',
                  dateFormat.format(twist.createdAt!),
                ),
              ],
              if (twist.updatedAt != null) ...[
                const SizedBox(height: 4),
                _buildMetadataRow(
                  context,
                  'Last updated',
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
