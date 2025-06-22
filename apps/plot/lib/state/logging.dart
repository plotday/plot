import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

final Logger log = Logger('plot.state');

class BlocLogger extends BlocObserver {
  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    super.onChange(bloc, change);
    log.info('${bloc.runtimeType}: $change');
  }

  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    super.onError(bloc, error, stackTrace);
    log.warning(bloc.runtimeType, error, stackTrace);
  }
}
