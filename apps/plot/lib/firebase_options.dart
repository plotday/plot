/// Firebase configuration options for Plot.
///
/// Values extracted from google-services.json (Android) and
/// GoogleService-Info.plist (iOS) in the Firebase console.
library;

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for this platform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBtlGt-1oo9-CQFQAesI1vZRJJOtuSKH7Q',
    appId: '1:535301598151:android:ed15ce39fb00bf612cc7e2',
    messagingSenderId: '535301598151',
    projectId: 'plot-core',
    storageBucket: 'plot-core.firebasestorage.app',
    databaseURL: 'https://plot-core.firebaseio.com',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDomfap0afxoxDWN107RbAnn-Q4cqjAnlA',
    appId: '1:535301598151:ios:4598b406ce2effea2cc7e2',
    messagingSenderId: '535301598151',
    projectId: 'plot-core',
    storageBucket: 'plot-core.firebasestorage.app',
    databaseURL: 'https://plot-core.firebaseio.com',
    iosBundleId: 'day.plot.app',
  );
}
