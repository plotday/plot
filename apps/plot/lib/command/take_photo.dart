import 'dart:io' show File;

import 'package:image_picker/image_picker.dart';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/util/image_utils.dart';
import 'package:plot/widget/widget.dart' hide Link;
import 'package:plot/store/store.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/network_exception.dart';
import 'logging.dart';

class TakePhoto extends Command {
  TakePhoto({
    required this.priorityId,
    required this.currentLinks,
    required this.onLinksChanged,
  }) : super(
          title: 'Take photo',
          eventObject: EventObject.note,
          eventAction: EventAction.added,
          icon: PlotIcon.camera,
        );

  final String priorityId;
  final List<UserAction> currentLinks;
  final void Function(List<UserAction> links) onLinksChanged;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final picker = ImagePicker();
    final XFile? photo;

    try {
      photo = await picker.pickImage(source: ImageSource.camera);
    } catch (e, t) {
      log.warning('Failed to open camera', e, t);
      return const CommandMessage(
        'Could not open camera. Please check permissions.',
        isError: true,
      );
    }

    if (photo == null) {
      return const CommandSkipped();
    }

    try {
      final response = await api.uploadFile(
        filePath: photo.path,
        fileName: photo.name,
        priorityId: priorityId,
      );

      int? imageWidth;
      int? imageHeight;
      final mimeType = response['mimeType'] as String;
      if (mimeType.startsWith('image/')) {
        final imageBytes = await File(photo.path).readAsBytes();
        final dims = await getImageDimensions(imageBytes);
        if (dims != null) {
          imageWidth = dims.$1;
          imageHeight = dims.$2;
        }
      }

      final fileLink = FileUserAction(
        fileId: response['fileId'] as String,
        fileName: response['fileName'] as String,
        fileSize: response['fileSize'] as int,
        mimeType: mimeType,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      );

      onLinksChanged([...currentLinks, fileLink]);
      return const CommandDone();
    } on NetworkException {
      return const CommandMessage(
        "You're offline. Please try again when connected.",
        isError: true,
      );
    } catch (e, t) {
      log.warning('Failed to upload photo', e, t);
      return const CommandMessage(
        'Failed to upload photo. Please try again.',
        isError: true,
      );
    }
  }
}
