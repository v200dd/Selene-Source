import 'package:flutter/material.dart';
import '../services/user_data_service.dart';
import '../services/watch_room_service.dart';

class WatchRoomScreen extends StatefulWidget {
  const WatchRoomScreen({super.key});
  @override
  State<WatchRoomScreen> createState() => _WatchRoomScreenState();
}

class _WatchRoomScreenState extends State<WatchRoomScreen> {
  static const _serverUrl =
      'https://watch-room-server-production-22a1.up.railway.app';
  late final WatchRoomService _service;
  List<WatchRoom> _rooms = const [];
  bool _connected = false;
  String? _error;
  String _userName = '游客';

  @override
  void initState() {
    super.initState();
    _service = WatchRoomService(serverUrl: _serverUrl);
    _connect();
  }

  Future<void> _connect() async {
    _userName = await UserDataService.getUsername() ?? '游客';
    _service.connect(
      onConnected: () {
        if (!mounted) return;
        setState(() {
          _connected = true;
          _error = null;
        });
        _refreshRooms();
      },
      onError: (message) {
        if (mounted) setState(() => _error = message);
      },
    );
  }

  void _refreshRooms() {
    _service.listRooms((rooms) {
      if (mounted) setState(() => _rooms = rooms);
    });
  }

  @override
  void dispose() {
    _service.leave();
    _service.dispose();
    super.dispose();
  }

  Future<void> _createRoom() async {
    final name = TextEditingController(text: '$_userName 的观影房');
    final password = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('创建观影房'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '房间名称')),
          TextField(
              controller: password,
              decoration: const InputDecoration(labelText: '密码（可选）'),
              obscureText: true),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('创建'))
        ],
      ),
    );
    if (result != true || !mounted) return;
    _service.createRoom(
      name: name.text.trim().isEmpty ? '观影房' : name.text.trim(),
      userName: _userName,
      password: password.text.trim().isEmpty ? null : password.text.trim(),
      onSuccess: (room) => _showRoomInfo(room, owner: true),
      onError: (message) => _showError(message),
    );
  }

  Future<void> _joinRoom(WatchRoom room) async {
    String? password;
    if (room.passwordProtected) {
      final controller = TextEditingController();
      final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('加入 ${room.name}'),
          content: TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(labelText: '房间密码')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: const Text('加入'))
          ],
        ),
      );
      if (result == null) return;
      password = result;
    }
    _service.joinRoom(
      roomId: room.id,
      userName: _userName,
      password: password,
      onSuccess: (joined) => _showRoomInfo(joined),
      onError: _showError,
    );
  }

  void _showRoomInfo(WatchRoom room, {bool owner = false}) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(room.name),
        content: Text(
            owner ? '房间已创建，房间号：${room.id}\n可以把房间号分享给朋友。' : '已加入房间：${room.id}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('知道了'))
        ],
      ),
    );
  }

  void _showError(String message) {
    if (mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => _refreshRooms(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            const Expanded(
                child: Text('观影房',
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
            FilledButton.icon(
                onPressed: _connected ? _createRoom : null,
                icon: const Icon(Icons.add),
                label: const Text('创建'))
          ]),
          const SizedBox(height: 6),
          Text(_connected ? '已连接观影房服务器' : '正在连接观影房服务器…',
              style: Theme.of(context).textTheme.bodySmall),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child:
                    Text(_error!, style: const TextStyle(color: Colors.red))),
          const SizedBox(height: 16),
          if (_rooms.isEmpty)
            const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: Text('暂无公开房间\n创建一个房间开始观影吧')))
          else
            ..._rooms.map(
              (room) => Card(
                child: ListTile(
                  leading: Icon(
                    room.passwordProtected ? Icons.lock : Icons.groups,
                  ),
                  title: Text(room.name),
                  subtitle: Text('${room.memberCount} 人 · 房间号 ${room.id}'),
                  trailing: FilledButton(
                    onPressed: _connected ? () => _joinRoom(room) : null,
                    child: const Text('加入'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
