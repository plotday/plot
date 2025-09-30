import 'package:web_socket_channel/web_socket_channel.dart';
import 'broadcast_channel_io.dart'
    if (dart.library.html) 'broadcast_channel_web.dart';

WebSocketChannel createWebSocketChannel(Uri uri, List<String> protocols) {
  return createWebSocketChannelImpl(uri, protocols);
}