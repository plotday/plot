import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

final Logger log = Logger('plot.state');

class BlocLogger extends BlocObserver {
  @override
  void onChange(BlocBase bloc, Change change) {
    super.onChange(bloc, change);
    log.info('${bloc.runtimeType} => $change');
  }
}
