import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/attachment_uploader.dart';
import 'package:plot/widget/widget.dart' hide Link;
import 'logging.dart';

/// Captures a photo and hands it to the editor as a [LocalAttachment]. The
/// editor shows the thumbnail immediately and uploads in the background, so this
/// command returns as soon as the photo is taken.
class TakePhoto extends Command {
  TakePhoto({required this.onAttach})
      : super(
          title: 'Take photo',
          eventObject: EventObject.note,
          eventAction: EventAction.added,
          icon: PlotIcon.camera,
        );

  final void Function(List<LocalAttachment> attachments) onAttach;

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

    final bytes = await photo.readAsBytes();
    final mimeType = lookupMimeType(photo.name) ?? 'image/jpeg';

    onAttach([
      LocalAttachment(
        fileName: photo.name,
        mimeType: mimeType,
        fileSize: bytes.lengthInBytes,
        bytes: bytes,
        filePath: photo.path,
      ),
    ]);

    return const CommandDone();
  }
}
