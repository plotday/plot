import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/priority.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';

class ReorderModeBottomBar extends StatelessWidget {
  const ReorderModeBottomBar({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: context.theme.colors.border,
              width: 1,
            ),
          ),
          color: context.theme.colors.background,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: context.theme.spacing.xl,
          vertical: context.theme.spacing.md,
        ),
        child: Row(
          children: [
            Icon(
              FontAwesomeIcons.gripDotsVertical,
              size: context.theme.iconSizes.sm,
              color: context.theme.plotColors.muted,
            ),
            SizedBox(width: context.theme.spacing.md),
            Expanded(
              child: Text(
                'Drag to reorder',
                style: context.theme.typography.sm.copyWith(
                  color: context.theme.plotColors.muted,
                ),
              ),
            ),
            GestureDetector(
              onTap: () {
                context.read<PriorityBloc>().setReorderMode(false);
              },
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: context.theme.spacing.lg,
                  vertical: context.theme.spacing.sm,
                ),
                decoration: BoxDecoration(
                  color: context.theme.colors.primary,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Done',
                  style: context.theme.typography.sm.copyWith(
                    color: context.theme.colors.primaryForeground,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
