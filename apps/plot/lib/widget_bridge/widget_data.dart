import 'package:equatable/equatable.dart';

/// Snapshot of the data exposed to native widgets and menubar/tray
/// surfaces. Written to platform shared storage so widget extensions
/// can read it during their own refresh cycles without invoking
/// Flutter.
///
/// The shape is intentionally minimal — only fields a widget could
/// plausibly render. Add new fields here when widget designs require
/// them; native readers tolerate missing keys.
class WidgetState extends Equatable {
  const WidgetState({
    required this.isSignedIn,
    this.userId,
    this.currentPriorityId,
    this.currentPriorityTitle,
  });

  factory WidgetState.signedOut() => const WidgetState(isSignedIn: false);

  final bool isSignedIn;
  final String? userId;
  final String? currentPriorityId;
  final String? currentPriorityTitle;

  Map<String, Object?> toJson() => {
    'isSignedIn': isSignedIn,
    'userId': userId,
    'currentPriorityId': currentPriorityId,
    'currentPriorityTitle': currentPriorityTitle,
  };

  @override
  List<Object?> get props => [
    isSignedIn,
    userId,
    currentPriorityId,
    currentPriorityTitle,
  ];
}
