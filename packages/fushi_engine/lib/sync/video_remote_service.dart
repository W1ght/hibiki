/// Application-owned video player adapter. The engine has no player dependency.
abstract interface class VideoRemoteService {
  Future<Map<String, Object?>> handle(
    String operation,
    Map<String, dynamic> body,
    String peerId,
  );
}

final class VideoRemoteException implements Exception {
  const VideoRemoteException(this.status, this.code);

  final int status;
  final String code;

  @override
  String toString() => 'VideoRemoteException($status, $code)';
}

const Set<String> videoRemoteOperations = <String>{
  'snapshot',
  'events',
  'subtitles',
  'command',
  'lookupBegin',
  'lookupEnd',
  'mine',
  'mineStatus',
  'favorites',
  'favoriteSet',
  'favoritesRemove',
  'openFavorite',
  'disconnect',
};
