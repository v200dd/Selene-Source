import 'package:socket_io_client/socket_io_client.dart' as io;

class WatchRoom {
  const WatchRoom({
    required this.id,
    required this.name,
    required this.memberCount,
    this.description = '',
    this.passwordProtected = false,
    this.roomType = 'sync',
  });

  final String id;
  final String name;
  final String description;
  final int memberCount;
  final bool passwordProtected;
  final String roomType;

  factory WatchRoom.fromJson(Map<String, dynamic> json) => WatchRoom(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '未命名房间').toString(),
        description: (json['description'] ?? '').toString(),
        memberCount: (json['memberCount'] as num?)?.toInt() ?? 0,
        passwordProtected: json['password'] != null,
        roomType: (json['roomType'] ?? 'sync').toString(),
      );
}

/// Socket.IO client for the standalone MoonTVPlus watch-room server.
class WatchRoomService {
  WatchRoomService({required this.serverUrl});

  final String serverUrl;
  io.Socket? _socket;

  void connect({
    required void Function() onConnected,
    void Function(String message)? onError,
  }) {
    _socket?.dispose();
    _socket = io.io(
        serverUrl,
        io.OptionBuilder()
            .setTransports(['websocket'])
            .disableAutoConnect()
            .enableReconnection()
            .build());
    _socket!
      ..onConnect((_) => onConnected())
      ..onError((error) => onError?.call(error.toString()))
      ..onConnectError((error) => onError?.call(error.toString()))
      ..connect();
  }

  void listRooms(void Function(List<WatchRoom>) callback) {
    _socket?.emitWithAck('room:list', null, ack: (data) {
      final list = data is List ? data : const [];
      callback(list
          .whereType<Map>()
          .map((item) => WatchRoom.fromJson(Map<String, dynamic>.from(item)))
          .toList());
    });
  }

  void createRoom({
    required String name,
    required String userName,
    String description = '',
    String? password,
    void Function(WatchRoom room)? onSuccess,
    void Function(String message)? onError,
  }) {
    _socket?.emitWithAck('room:create', {
      'name': name,
      'description': description,
      'password': password,
      'isPublic': true,
      'userName': userName,
      'roomType': 'sync',
    }, ack: (data) {
      final map =
          data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      if (map['success'] == true && map['room'] is Map) {
        onSuccess
            ?.call(WatchRoom.fromJson(Map<String, dynamic>.from(map['room'])));
      } else {
        onError?.call((map['error'] ?? '创建房间失败').toString());
      }
    });
  }

  void joinRoom({
    required String roomId,
    required String userName,
    String? password,
    void Function(WatchRoom room)? onSuccess,
    void Function(String message)? onError,
  }) {
    _socket?.emitWithAck('room:join', {
      'roomId': roomId,
      'password': password,
      'userName': userName,
    }, ack: (data) {
      final map =
          data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      if (map['success'] == true && map['room'] is Map) {
        onSuccess
            ?.call(WatchRoom.fromJson(Map<String, dynamic>.from(map['room'])));
      } else {
        onError?.call((map['error'] ?? '加入房间失败').toString());
      }
    });
  }

  void leave() => _socket?.emit('room:leave');

  void dispose() {
    _socket?.dispose();
    _socket = null;
  }
}
