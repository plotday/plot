import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

WebSocketChannel createWebSocketChannelImpl(
  Uri uri,
  List<String> protocols,
) {
  return IOWebSocketChannel.connect(uri, protocols: protocols);
}