import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/html.dart';

WebSocketChannel createWebSocketChannelImpl(
  Uri uri,
  List<String> protocols,
) {
  return HtmlWebSocketChannel.connect(uri, protocols: protocols);
}