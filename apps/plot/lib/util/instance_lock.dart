import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:logging/logging.dart';

/// Manages single-instance enforcement per profile using file locks
class InstanceLock {
  static final Logger _log = Logger('InstanceLock');

  final String profile;
  RandomAccessFile? _lockFile;
  Timer? _requestWatcher;
  void Function(String)? _onDeepLinkReceived;

  InstanceLock(this.profile);

  /// Try to acquire the instance lock for this profile
  /// Returns true if lock acquired, false if another instance is running
  Future<bool> tryAcquire() async {
    try {
      final lockDir = await _getLockDirectory();
      final lockFilePath = '${lockDir.path}/profile-$profile.lock';
      final lockFile = File(lockFilePath);

      // Try to open with exclusive lock
      _lockFile = await lockFile.open(mode: FileMode.write);
      await _lockFile!.lock(FileLock.exclusive);

      // Write PID for debugging
      await _lockFile!.writeString('$pid\n');
      await _lockFile!.flush();

      _log.info('Acquired lock for profile "$profile"');
      return true;
    } catch (e) {
      _log.info('Another instance of profile "$profile" is running');
      return false;
    }
  }

  /// Send a deep link request to the running instance
  Future<void> sendDeepLinkRequest(String? deepLink) async {
    final lockDir = await _getLockDirectory();
    final requestFile = File('${lockDir.path}/profile-$profile.request');

    await requestFile.writeAsString(deepLink ?? '');
    _log.info('Sent deep link request to running instance: $deepLink');
  }

  /// Start watching for deep link requests from other instances
  void startWatching(void Function(String) onDeepLinkReceived) {
    _onDeepLinkReceived = onDeepLinkReceived;

    _requestWatcher = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _checkForRequests(),
    );
  }

  Future<void> _checkForRequests() async {
    try {
      final lockDir = await _getLockDirectory();
      final requestFile = File('${lockDir.path}/profile-$profile.request');

      if (await requestFile.exists()) {
        final deepLink = await requestFile.readAsString();
        await requestFile.delete();

        if (_onDeepLinkReceived != null) {
          _onDeepLinkReceived!(deepLink);
        }
      }
    } catch (e) {
      // Ignore errors during request checking
    }
  }

  Future<Directory> _getLockDirectory() async {
    final appSupport = await getApplicationSupportDirectory();
    final lockDir = Directory('${appSupport.path}/locks');

    if (!await lockDir.exists()) {
      await lockDir.create(recursive: true);
    }

    return lockDir;
  }

  /// Release the lock and stop watching
  Future<void> release() async {
    _requestWatcher?.cancel();

    if (_lockFile != null) {
      try {
        await _lockFile!.unlock();
        await _lockFile!.close();

        // Clean up lock file
        final lockDir = await _getLockDirectory();
        final lockFilePath = '${lockDir.path}/profile-$profile.lock';
        final lockFile = File(lockFilePath);
        if (await lockFile.exists()) {
          await lockFile.delete();
        }

        _log.info('Released lock for profile "$profile"');
      } catch (e) {
        _log.warning('Error releasing lock', e);
      }
    }
  }
}
