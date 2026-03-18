# Thread Finishing Motion Design

## Summary

Add exit animations and height-collapse transitions when finishing threads in the agenda view. Mobile gets a swipe-momentum slide-off; desktop gets a fade-out with icon pulse. Both platforms share a fast height-collapse to close the gap left by the removed thread.

## Context

Currently, finishing a thread fires `HapticFeedback.mediumImpact()` and then the thread vanishes instantly via an optimistic state update — no exit animation, no visual transition. The remaining items snap into place with no collapse animation.

## Design

### Approach: Hybrid (Platform-Native)

Each platform gets its most natural exit treatment:

- **Mobile (swipe-right):** Thread accelerates off-screen in the swipe direction, then the gap collapses.
- **Desktop (icon click):** Icon pulses, thread fades out, then the gap collapses.

Both share ~230ms total duration — fast enough to feel decisive, slow enough to be perceptible.

### Mobile Swipe Timeline

| Time | Event |
|------|-------|
| 0ms | Swipe released in active zone. Swipeable's `lightImpact` already fired at threshold crossing. |
| 0ms | Thread slides off-screen right (150ms, `Curves.easeIn`). FinishThread fires `mediumImpact()`. |
| +80ms | Height collapse begins (150ms, `Curves.easeOut`). Overlaps the tail of the slide-off. |
| +230ms | Complete. Item removed from layout, optimistic state update fires. |

Key change to `Swipeable`: instead of sliding back to origin on release, when `exitOnActivation` is set, the thread accelerates off-screen in the drag direction.

### Desktop Click Timeline

| Time | Event |
|------|-------|
| 0ms | Click finish icon. Icon scale pulse: 1.0 → 1.15 → 1.0 (100ms, `Curves.easeOut`). |
| +50ms | Thread fades out: opacity 1.0 → 0.0 (120ms, `Curves.easeOut`). |
| +80ms | Height collapse begins (150ms, `Curves.easeOut`). |
| +230ms | Complete. Item removed from layout, optimistic state update fires. |

### Haptics (Mobile Only)

No changes to the existing haptic pattern:

| Moment | Haptic | Source |
|--------|--------|--------|
| Swipe crosses 80px threshold | `lightImpact` | `Swipeable` (existing) |
| Swipe released in active zone | `mediumImpact` | `FinishThread` (existing) |

### Scheduled Thread Copies

No change. When finishing a thread that has a link schedule instance elsewhere in the agenda, the scheduled copy stays in the list. Only the todo entry (the item the user directly acted on) is removed with animation. This matches the current `optimisticallyRemoveThread` behavior which keeps `isLinkScheduleInstance` items.

### No Undo

Finishing is immediate and final. No toast, no undo mechanism.

## Architecture

### 1. `Swipeable` Enhancement (`widget/swipeable.dart`)

Add an `exitOnActivation` callback:

```dart
class Swipeable extends StatefulWidget {
  // ... existing fields ...

  /// When set, on release in an active zone the child slides off-screen
  /// instead of sliding back. The callback receives the resolved command
  /// and a Future that completes when the slide-off animation finishes.
  final Future<void> Function(Command command)? exitOnActivation;
}
```

Behavior change in `_onHorizontalDragEnd`:
- **Without `exitOnActivation`** (default): Current behavior — slides back, then executes command.
- **With `exitOnActivation`**: Animates `_dragOffset` to ±screen width (150ms, `Curves.easeIn`), then calls `exitOnActivation(command)`. Does NOT execute the command via `context.run()` — the callback handles that.

### 2. `AnimatedRemoval` Widget (`widget/animated_removal.dart`)

New widget that wraps each thread item in the agenda list. Manages the height collapse and (on desktop) the fade-out + icon pulse.

```dart
class AnimatedRemoval extends StatefulWidget {
  final Widget child;
  final Duration collapseDuration;  // default: 150ms
  final Duration collapseDelay;     // default: 80ms
  final Duration fadeDuration;      // default: 120ms (desktop only)
  final Duration fadeDelay;         // default: 50ms (desktop only)
  final Curve collapseCurve;        // default: Curves.easeOut
  final VoidCallback? onRemoved;    // called when all animations complete
}

class AnimatedRemovalState extends State<AnimatedRemoval> {
  /// Trigger the removal animation sequence.
  /// On mobile: just height collapse (slide-off handled by Swipeable).
  /// On desktop: fade + height collapse.
  Future<void> remove({bool fade = false});
}
```

Usage via `GlobalKey<AnimatedRemovalState>` to call `remove()` imperatively.

### 3. `Swipeable` Wiring in `widget/thread.dart`

`Swipeable` lives inside `ThreadWidget.build()` (not in `priority.dart`). The `exitOnActivation` callback is passed into `ThreadWidget` as a new optional parameter:

```dart
class ThreadWidget extends StatefulWidget {
  // ... existing fields ...
  final Future<void> Function(Command command)? onSwipeExit;
}
```

Inside `ThreadWidget`, when constructing `Swipeable`:

```dart
Swipeable(
  startCommand: swipeRightShort,
  exitOnActivation: widget.onSwipeExit,
  child: listTile,
)
```

### 4. Integration and Coordination in `page/priority.dart`

`priority.dart` is the single coordination point — it owns the `AnimatedRemoval` wrapper and connects it to `ThreadWidget`'s swipe exit:

```dart
activity: (agendaActivity) {
  final removalKey = GlobalKey<AnimatedRemovalState>();
  return [
    AnimatedRemoval(
      key: removalKey,
      onRemoved: () {
        // After animation completes, fire the optimistic state update
        context.read<PriorityBloc>().optimisticallyRemoveThread(
          agendaActivity.thread.id,
        );
      },
      child: ThreadWidget(
        activity: agendaActivity.thread,
        onSwipeExit: (command) async {
          // Swipeable slid the thread off-screen; now collapse the gap
          await removalKey.currentState?.remove();
          // Then execute the command (FinishThread, etc.)
          await context.run(command);
        },
        /* ... existing params ... */
      ),
    ),
  ];
}
```

For **desktop icon click**: `FinishThread.run()` looks up the `AnimatedRemovalState` and calls `remove(fade: true)` before the optimistic removal. The `AnimatedRemoval` key is accessible via a registry or `BuildContext` lookup (e.g., an `InheritedWidget` or a map keyed by thread ID maintained in the priority page state).

This approach keeps all animation orchestration in `priority.dart`, with `Swipeable` and `AnimatedRemoval` as dumb, reusable animation primitives.

## Files Changed

| File | Change |
|------|--------|
| `apps/plot/lib/widget/swipeable.dart` | Add `exitOnActivation` callback, slide-off animation path |
| `apps/plot/lib/widget/animated_removal.dart` | New widget — height collapse + optional fade |
| `apps/plot/lib/widget/thread.dart` | Add `onSwipeExit` parameter, pass through to `Swipeable.exitOnActivation` |
| `apps/plot/lib/page/priority.dart` | Wrap agenda threads in `AnimatedRemoval`, wire up swipe exit and desktop finish coordination |
| `apps/plot/lib/command/thread.dart` | Move `optimisticallyRemoveThread` call to after animation; look up `AnimatedRemovalState` for desktop path |

## Curves and Durations Reference

| Animation | Duration | Curve | Notes |
|-----------|----------|-------|-------|
| Slide off-screen (mobile) | 150ms | `Curves.easeIn` | Accelerates to feel momentum-based |
| Icon scale pulse (desktop) | 100ms | `Curves.easeOut` | 1.0 → 1.15 → 1.0 |
| Fade out (desktop) | 120ms | `Curves.easeOut` | Starts at +50ms |
| Height collapse (both) | 150ms | `Curves.easeOut` | Starts at +80ms, decelerates to settle |
