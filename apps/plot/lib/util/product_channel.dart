/// Channels on a composite connection are namespaced `<productKey>:<rawId>`.
/// These helpers parse/group by that prefix; raw ids may themselves contain `:`.
String? productKeyOf(String channelKey) {
  final i = channelKey.indexOf(':');
  return i <= 0 ? null : channelKey.substring(0, i);
}

String rawChannelId(String channelKey) {
  final i = channelKey.indexOf(':');
  return i < 0 ? channelKey : channelKey.substring(i + 1);
}
