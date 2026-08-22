import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'user_data_service.dart';

/// 主站下发的观影房配置。
///
/// 服务器地址和认证密钥都由主站的 `/api/watch-room/config` 管理。写死在 App 里
/// 不行：换站点、换服务器、改密钥都要重新打包，而且密钥一旦对不上，服务器会在
/// 握手校验后立刻把客户端踢下线。
class WatchRoomConfig {
  const WatchRoomConfig({
    required this.enabled,
    required this.serverUrl,
    required this.authKey,
  });

  final bool enabled;
  final String serverUrl;
  final String authKey;

  static const disabled =
      WatchRoomConfig(enabled: false, serverUrl: '', authKey: '');

  /// 拉主站配置。只有 POST 会带上 authKey，GET 只返回地址。
  static Future<WatchRoomConfig> fetch() async {
    final baseUrl = await UserDataService.getServerUrl();
    if (baseUrl == null || baseUrl.isEmpty) return disabled;
    final root = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final cookies = await UserDataService.getCookies();
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    if (cookies != null && cookies.isNotEmpty) {
      headers['Cookie'] = cookies;
    }
    try {
      final response = await http
          .post(Uri.parse('$root/api/watch-room/config'), headers: headers)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return disabled;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return disabled;
      final serverUrl = (decoded['serverUrl'] ?? '')
          .toString()
          .trim()
          .replaceAll(RegExp(r'/+$'), '');
      return WatchRoomConfig(
        enabled: decoded['enabled'] == true && serverUrl.isNotEmpty,
        serverUrl: serverUrl,
        authKey: (decoded['authKey'] ?? '').toString().trim(),
      );
    } catch (_) {
      return disabled;
    }
  }
}

/// 房间成员。
class WatchRoomMember {
  const WatchRoomMember({
    required this.id,
    required this.name,
    required this.isOwner,
  });

  final String id;
  final String name;
  final bool isOwner;

  factory WatchRoomMember.fromJson(Map<String, dynamic> json) =>
      WatchRoomMember(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '游客').toString(),
        isOwner: json['isOwner'] == true,
      );
}

class WatchRoom {
  const WatchRoom({
    required this.id,
    required this.name,
    required this.memberCount,
    this.description = '',
    this.passwordProtected = false,
    this.roomType = 'sync',
    this.isPublic = true,
    this.ownerName = '',
    this.ownerToken = '',
  });

  final String id;
  final String name;
  final String description;
  final int memberCount;
  final bool passwordProtected;
  final String roomType;
  final bool isPublic;
  final String ownerName;

  /// 房主令牌，只有创建者拿得到。断线重连时带上它才能恢复房主身份。
  final String ownerToken;

  factory WatchRoom.fromJson(Map<String, dynamic> json) => WatchRoom(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '未命名房间').toString(),
        description: (json['description'] ?? '').toString(),
        memberCount: (json['memberCount'] as num?)?.toInt() ?? 0,
        passwordProtected: (json['password'] ?? '').toString().isNotEmpty,
        roomType: (json['roomType'] ?? 'sync').toString(),
        isPublic: json['isPublic'] != false,
        ownerName: (json['ownerName'] ?? '').toString(),
        ownerToken: (json['ownerToken'] ?? '').toString(),
      );

  WatchRoom copyWith({int? memberCount}) => WatchRoom(
        id: id,
        name: name,
        description: description,
        memberCount: memberCount ?? this.memberCount,
        passwordProtected: passwordProtected,
        roomType: roomType,
        isPublic: isPublic,
        ownerName: ownerName,
        ownerToken: ownerToken,
      );
}

/// 独立观影房服务器（watch-room-server）的 Socket.IO 客户端。
///
/// 服务器在 `connection` 时就校验握手里的 token：不带或者不匹配会先
/// `emit('error', 'Unauthorized')` 再 `disconnect(true)`。所以 socket 触发过
/// `connect` 不等于可用，得等确认没被踢掉才算真连上。
class WatchRoomService {
  WatchRoomService({required this.serverUrl, required this.authKey});

  final String serverUrl;
  final String authKey;
  io.Socket? _socket;
  Timer? _heartbeatTimer;

  bool get connected => _socket?.connected == true;

  void connect({
    required void Function() onConnected,
    void Function(String message)? onError,
    void Function()? onDisconnected,
    void Function(WatchRoomMember member)? onMemberJoined,
    void Function(String userId)? onMemberLeft,
    void Function()? onRoomDeleted,
  }) {
    _socket?.dispose();
    // token 同时放握手 auth 和 Authorization 头：服务器读的是 auth.token，
    // 但中间的反向代理有时会丢掉自定义握手数据，两处都给更稳。
    final options = io.OptionBuilder()
        .setTransports(['websocket'])
        .disableAutoConnect()
        .enableForceNew()
        .enableReconnection()
        .setAuth({'token': authKey})
        .setExtraHeaders({'Authorization': 'Bearer $authKey'})
        .build();
    _socket = io.io(serverUrl, options);
    _socket!
      ..onConnect((_) => onConnected())
      ..on('error', (data) => onError?.call(_describe(data)))
      ..onError((error) => onError?.call(_describe(error)))
      ..onConnectError((error) => onError?.call(_describe(error)))
      ..onDisconnect((_) {
        stopHeartbeat();
        onDisconnected?.call();
      })
      ..on('room:member-joined', (data) {
        if (data is Map) {
          onMemberJoined
              ?.call(WatchRoomMember.fromJson(Map<String, dynamic>.from(data)));
        }
      })
      ..on('room:member-left', (data) => onMemberLeft?.call(data.toString()))
      ..on('room:deleted', (_) {
        stopHeartbeat();
        onRoomDeleted?.call();
      })
      ..connect();
  }

  /// 服务器 30 秒收不到房主心跳会清掉播放状态，5 分钟没心跳直接删房间。
  void startHeartbeat() {
    _heartbeatTimer?.cancel();
    _socket?.emit('heartbeat');
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _socket?.emit('heartbeat'),
    );
  }

  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// 拉公开房间列表。服务器的 `room:list` 只吃 ack 回调，不带 payload。
  void listRooms(void Function(List<WatchRoom>) callback) {
    if (_socket?.connected != true) {
      callback(const []);
      return;
    }
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
    bool isPublic = true,
    void Function(WatchRoom room)? onSuccess,
    void Function(String message)? onError,
  }) {
    if (_socket?.connected != true) {
      onError?.call('还没连上观影房服务器');
      return;
    }
    _socket?.emitWithAck('room:create', {
      'name': name,
      'description': description,
      'password': password,
      'isPublic': isPublic,
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
    String? ownerToken,
    void Function(WatchRoom room, List<WatchRoomMember> members)? onSuccess,
    void Function(String message)? onError,
  }) {
    if (_socket?.connected != true) {
      onError?.call('还没连上观影房服务器');
      return;
    }
    _socket?.emitWithAck('room:join', {
      'roomId': roomId,
      'password': password,
      'userName': userName,
      'ownerToken': ownerToken,
    }, ack: (data) {
      final map =
          data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      if (map['success'] == true && map['room'] is Map) {
        final rawMembers = map['members'];
        final members = (rawMembers is List ? rawMembers : const [])
            .whereType<Map>()
            .map((item) =>
                WatchRoomMember.fromJson(Map<String, dynamic>.from(item)))
            .toList();
        onSuccess?.call(
          WatchRoom.fromJson(Map<String, dynamic>.from(map['room'])),
          members,
        );
      } else {
        onError?.call((map['error'] ?? '加入房间失败').toString());
      }
    });
  }

  void leave() {
    stopHeartbeat();
    _socket?.emit('room:leave');
  }

  void dispose() {
    stopHeartbeat();
    _socket?.dispose();
    _socket = null;
  }

  static String _describe(dynamic error) {
    final text = error?.toString() ?? '';
    if (text.contains('Unauthorized')) {
      return '认证失败：主站配置的观影房密钥与服务器不一致';
    }
    return text.isEmpty ? '连接观影房服务器失败' : text;
  }
}
