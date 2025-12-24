import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'logging.dart';

/// A button that enables speech dictation functionality.
///
/// When tapped, it starts listening to user's speech and returns the
/// transcribed text via the [onResult] callback.
class SpeechDictationButton extends StatefulWidget {
  const SpeechDictationButton({
    required this.onResult,
    this.onError,
    super.key,
  });

  /// Called when speech is successfully transcribed
  final void Function(String text) onResult;

  /// Called when an error occurs during speech recognition
  final void Function(String error)? onError;

  @override
  State<SpeechDictationButton> createState() => _SpeechDictationButtonState();
}

class _SpeechDictationButtonState extends State<SpeechDictationButton> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  bool _isAvailable = false;
  bool _isInitialized = false;
  bool _isUnsupported = false;

  @override
  void initState() {
    super.initState();
    // Don't initialize speech here - wait for user to tap the button
  }

  Future<void> _initSpeech() async {
    try {
      _isAvailable = await _speech.initialize(
        onError: (error) {
          log.warning('Speech recognition error: ${error.errorMsg}');
          if (mounted) {
            setState(() => _isListening = false);
            _handleError(error.errorMsg);
          }
        },
        onStatus: (status) {
          if (mounted && (status == 'done' || status == 'notListening')) {
            setState(() => _isListening = false);
          }
        },
      );
      if (mounted) {
        setState(() => _isInitialized = true);
      }
      if (!_isAvailable) {
        // Permission denied or not available - don't show error, let user try again
        log.warning('Speech recognition not available (likely permission denied)');
      }
    } catch (e) {
      // Exception means device doesn't support speech recognition
      log.warning('Failed to initialize speech recognition: $e');
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _isUnsupported = true;
        });
        _handleError('Speech recognition is not available on this device');
      }
    }
  }

  void _handleError(String error) {
    if (widget.onError != null) {
      log.warning('Handling speech recognition error: $error');
      widget.onError!(error);
    }
  }

  Future<void> _toggleListening() async {
    // Initialize speech on first use
    if (!_isInitialized) {
      await _initSpeech();
      // If initialization failed due to unsupported device, error already shown
      if (_isUnsupported) {
        return;
      }
      // If permission denied, button stays visible - user can try again later
      if (!_isAvailable) {
        return;
      }
    }

    // Check if speech is available after initialization
    if (!_isAvailable) {
      // Don't show error - user can try again if they change permissions
      return;
    }

    if (_isListening) {
      // Stop listening
      await _speech.stop();
      setState(() => _isListening = false);
    } else {
      // Start listening
      setState(() => _isListening = true);
      await _speech.listen(
        onResult: (result) {
          // Only process final results
          if (result.finalResult) {
            final text = result.recognizedWords;
            log.info('Speech recognized: $text');
            widget.onResult(text);
            if (mounted) {
              setState(() => _isListening = false);
            }
          }
        },
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          cancelOnError: true,
          partialResults: false,
        ),
      );
    }
  }

  @override
  void dispose() {
    _speech.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Only hide button if device doesn't support speech recognition
    if (_isUnsupported) {
      return const SizedBox.shrink();
    }

    // Show button even if not initialized or permission denied
    // User can tap to request permissions or try again
    return FButton.icon(
      onPress: _toggleListening,
      style: _buildButtonStyle(context),
      child: Icon(FontAwesomeIcons.microphone, size: 15),
    );
  }

  FButtonStyle _buildButtonStyle(BuildContext context) {
    final baseStyle = _isListening
        ? context.theme.buttonStyles.primary
        : context.theme.buttonStyles.ghost;

    // ignore: unused_result
    return baseStyle.copyWith(
      // ignore: unused_result
      iconContentStyle: baseStyle.iconContentStyle.copyWith(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      ),
      decoration: baseStyle.decoration.map(
        (decoration) =>
            decoration.copyWith(borderRadius: BorderRadius.circular(999)),
      ),
    );
  }
}
