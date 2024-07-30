import 'dart:math';
import 'package:equatable/equatable.dart';

class Order extends Equatable implements Comparable<Order> {
  static String _generate() {
    return "O${DateTime.now().millisecondsSinceEpoch.toString()}";
  }

  static String _between(Order? after, Order? before) {
    var str1 = after?.value;
    var str2 = before?.value;
    if (str1 == null) {
      if (str2 == null) return _generate();
      str1 = String.fromCharCode(max(32, str2.codeUnitAt(0) - 1));
    } else {
      str2 ??= String.fromCharCode(min(126, str1.codeUnitAt(0) + 1));
    }

    String newStr = "";
    for (int i = 0; true; i++) {
      final c1 = i < str1.length ? str1.codeUnitAt(i) : 32;
      final c2 = i < str2.length ? str2.codeUnitAt(i) : 126;
      final cn = ((c1 + c2) / 2).floor();

      if (c1 == cn || c2 == cn) {
        newStr += str1[i];
        continue;
      }

      newStr += String.fromCharCode(cn);
      break;
    }
    return newStr;
  }

  Order() : value = _generate();

  const Order.fromString(this.value);

  Order.between(Order? after, Order? before) : value = _between(after, before);
  Order.firstPinned({required Order? firstPinned})
      : value = _between(null, firstPinned);
  Order.lastPinned({required Order? lastPinned})
      : value = _between(lastPinned ?? const Order.fromString('!'), null);
  Order.first({required Order? first}) : value = _between(null, first);
  Order.last({required Order? last}) : value = _between(last, null);

  @override
  int compareTo(Order other) {
    return value.compareTo(other.value);
  }

  bool get pinned => value.startsWith('!');

  final String value;

  @override
  List<Object?> get props => [value];
}
