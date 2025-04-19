import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

class BlocLogger extends BlocObserver {
  final Logger _logger = Logger('BlocObserver');

  @override
  void onChange(BlocBase bloc, Change change) {
    super.onChange(bloc, change);
    _logger.info('${bloc.runtimeType} => $change');
  }
}
