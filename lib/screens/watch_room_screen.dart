import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/user_data_service.dart';
import '../services/watch_room_service.dart';
import '../utils/font_utils.dart';

/// 观影房。
///
/// 结构对齐网页版：三个页签（创建房间 / 加入房间 / 房间列表），进房之后整页
/// 换成房间面板，显示房间号、成员数、成员列表和退出（房主是解散）。
///
/// 之前「创建之后没反应」的根因不在 UI：服务器在握手时就校验 `auth.token`，
/// 老实现完全没带 token，于是服务器 `emit('error','Unauthorized')` 后立刻
/// `disconnect(true)`。Socket.IO 客户端此时已经触发过一次 `connect`，界面就显示
/// 「已连接」，但任何 `emitWithAck` 都发不出去也永远等不到 ack —— 表现就是点了
/// 创建毫无反应。token 由主站 `/api/watch-room/config` 下发。
class WatchRoomScreen extends StatefulWidget {
  const WatchRoomScreen({super.key});

  @override
  State<WatchRoomScreen> createState() => _WatchRoomScreenState();
}

enum _ConnectionState { connecting, connected, failed, disabled }

class _WatchRoomScreenState extends State<WatchRoomScreen>
    with
        SingleTickerProviderStateMixin,
        AutomaticKeepAliveClientMixin<WatchRoomScreen> {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  WatchRoomService? _service;
  _ConnectionState _state = _ConnectionState.connecting;
  String? _error;
  String _userName = '游客';

  List<WatchRoom> _rooms = const [];
  bool _loadingRooms = false;

  /// 当前所在房间。非空时整页切换成房间面板。
  WatchRoom? _room;
  List<WatchRoomMember> _members = const [];
  bool _isOwner = false;

  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _createPasswordController = TextEditingController();
  final _roomIdController = TextEditingController();
  final _joinPasswordController = TextEditingController();
  bool _isPublic = true;
  bool _busy = false;

  // 底栏使用 PageView。观影房离开可视范围后如果被回收，dispose 会断开
  // Socket.IO 并向服务器离房；房主是最后一名成员时服务器会随即删房。
  // 保持页面存活，让用户切到电影并进入播放器后仍留在原房间。
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _service?.leave();
    _service?.dispose();
    _tabs.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    _createPasswordController.dispose();
    _roomIdController.dispose();
    _joinPasswordController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _state = _ConnectionState.connecting;
      _error = null;
    });

    _userName = await UserDataService.getUsername() ?? '游客';
    if (!mounted) return;
    _nameController.text = '$_userName 的观影房';

    final config = await WatchRoomConfig.fetch();
    if (!mounted) return;

    if (!config.enabled) {
      setState(() {
        _state = _ConnectionState.disabled;
        _error = '主站没有启用观影房。请在 LunaTV 后台的「观影室配置」里启用并填写服务器地址。';
      });
      return;
    }
    if (config.authKey.isEmpty) {
      setState(() {
        _state = _ConnectionState.failed;
        _error = '主站没有下发观影房认证密钥，服务器会拒绝连接。请在后台补上「认证密钥」。';
      });
      return;
    }

    _service?.dispose();
    final service = WatchRoomService(
      serverUrl: config.serverUrl,
      authKey: config.authKey,
    );
    _service = service;
    service.connect(
      onConnected: () {
        if (!mounted) return;
        setState(() {
          _state = _ConnectionState.connected;
          _error = null;
        });
        _refreshRooms();
      },
      onError: (message) {
        if (!mounted) return;
        setState(() {
          _state = _ConnectionState.failed;
          _error = message;
        });
      },
      onDisconnected: () {
        if (!mounted) return;
        setState(() {
          if (_state == _ConnectionState.connected) {
            _state = _ConnectionState.connecting;
          }
          _room = null;
          _members = const [];
          _isOwner = false;
        });
      },
      onMemberJoined: (member) {
        if (!mounted) return;
        setState(() {
          _members = [..._members.where((m) => m.id != member.id), member];
          _room = _room?.copyWith(memberCount: _members.length);
        });
      },
      onMemberLeft: (userId) {
        if (!mounted) return;
        setState(() {
          _members = _members.where((m) => m.id != userId).toList();
          _room = _room?.copyWith(memberCount: _members.length);
        });
      },
      onRoomDeleted: () {
        if (!mounted) return;
        setState(() {
          _room = null;
          _members = const [];
          _isOwner = false;
        });
        _snack('房间已解散');
        _refreshRooms();
      },
    );
  }

  void _refreshRooms() {
    final service = _service;
    if (service == null || !service.connected) return;
    setState(() => _loadingRooms = true);
    service.listRooms((rooms) {
      if (!mounted) return;
      setState(() {
        _rooms = rooms;
        _loadingRooms = false;
      });
    });
  }

  Future<void> _createRoom() async {
    final service = _service;
    if (service == null) return;
    final name = _nameController.text.trim();
    setState(() => _busy = true);
    service.createRoom(
      name: name.isEmpty ? '$_userName 的观影房' : name,
      description: _descriptionController.text.trim(),
      password: _createPasswordController.text.trim().isEmpty
          ? null
          : _createPasswordController.text.trim(),
      isPublic: _isPublic,
      userName: _userName,
      onSuccess: (room) {
        if (!mounted) return;
        // 创建者不会收到自己的 member-joined，成员列表要本地补上。
        setState(() {
          _busy = false;
          _room = room;
          _isOwner = true;
          _members = [
            WatchRoomMember(id: 'self', name: _userName, isOwner: true),
          ];
        });
        service.startHeartbeat();
      },
      onError: (message) {
        if (!mounted) return;
        setState(() => _busy = false);
        _snack(message);
      },
    );
  }

  Future<void> _joinById() async {
    final roomId = _roomIdController.text.trim().toUpperCase();
    if (roomId.isEmpty) {
      _snack('请输入房间号');
      return;
    }
    _join(
      roomId: roomId,
      password: _joinPasswordController.text.trim().isEmpty
          ? null
          : _joinPasswordController.text.trim(),
    );
  }

  Future<void> _joinFromList(WatchRoom room) async {
    String? password;
    if (room.passwordProtected) {
      password = await _askPassword(room.name);
      if (password == null) return;
    }
    _join(roomId: room.id, password: password);
  }

  void _join({required String roomId, String? password}) {
    final service = _service;
    if (service == null) return;
    setState(() => _busy = true);
    service.joinRoom(
      roomId: roomId,
      userName: _userName,
      password: password,
      onSuccess: (room, members) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _room = room;
          _members = members;
          _isOwner = false;
        });
        service.startHeartbeat();
      },
      onError: (message) {
        if (!mounted) return;
        setState(() => _busy = false);
        _snack(message);
      },
    );
  }

  Future<String?> _askPassword(String roomName) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('加入 $roomName'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: '房间密码'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('加入'),
          ),
        ],
      ),
    );
  }

  void _leaveRoom() {
    _service?.leave();
    setState(() {
      _room = null;
      _members = const [];
      _isOwner = false;
    });
    _refreshRooms();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_room != null) return _buildRoomPanel(context, _room!);

    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '观影房',
                  style: FontUtils.poppins(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _StatusPill(state: _state, onRetry: _bootstrap),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.group_add_outlined), text: '创建房间'),
            Tab(icon: Icon(Icons.login), text: '加入房间'),
            Tab(icon: Icon(Icons.format_list_bulleted), text: '房间列表'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _buildCreateTab(theme),
              _buildJoinTab(theme),
              _buildListTab(theme),
            ],
          ),
        ),
      ],
    );
  }

  bool get _actionable => _state == _ConnectionState.connected && !_busy;

  Widget _buildCreateTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('创建新房间',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(
            labelText: '房间名称',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _descriptionController,
          decoration: const InputDecoration(
            labelText: '房间描述（可选）',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _createPasswordController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '房间密码（可选）',
            border: OutlineInputBorder(),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _isPublic,
          onChanged: (value) => setState(() => _isPublic = value),
          title: const Text('公开房间'),
          subtitle: const Text('公开房间会出现在房间列表里，其他人可以直接看到并加入'),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _actionable ? _createRoom : null,
          icon: const Icon(Icons.add),
          label: Text(_busy ? '创建中…' : '创建房间'),
        ),
      ],
    );
  }

  Widget _buildJoinTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('加入房间',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        TextField(
          controller: _roomIdController,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: '房间号',
            hintText: '例如 I8VEAY',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _joinPasswordController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '房间密码（如果有）',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _actionable ? _joinById : null,
          icon: const Icon(Icons.login),
          label: Text(_busy ? '加入中…' : '加入房间'),
        ),
      ],
    );
  }

  Widget _buildListTab(ThemeData theme) {
    return RefreshIndicator(
      onRefresh: () async => _refreshRooms(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text('公开房间',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              IconButton(
                onPressed:
                    _state == _ConnectionState.connected ? _refreshRooms : null,
                icon: const Icon(Icons.refresh),
                tooltip: '刷新',
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_loadingRooms && _rooms.isEmpty)
            const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_rooms.isEmpty)
            const Padding(
              padding: EdgeInsets.all(48),
              child: Center(
                child: Text('暂无公开房间\n下拉可以刷新，或者自己创建一个',
                    textAlign: TextAlign.center),
              ),
            )
          else
            ..._rooms.map(
              (room) => Card(
                child: ListTile(
                  leading: Icon(
                    room.passwordProtected ? Icons.lock : Icons.groups,
                  ),
                  title: Text(room.name),
                  subtitle: Text(
                    '${room.memberCount} 人 · 房间号 ${room.id}'
                    '${room.ownerName.isEmpty ? '' : ' · 房主 ${room.ownerName}'}',
                  ),
                  trailing: FilledButton(
                    onPressed: _actionable ? () => _joinFromList(room) : null,
                    child: const Text('加入'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRoomPanel(BuildContext context, WatchRoom room) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF6366F1), Color(0xFFA21CF0)],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      room.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (_isOwner) const _Badge(text: '房主'),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                room.description.isEmpty ? '暂无描述' : room.description,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _StatTile(
                      label: '房间号',
                      value: room.id,
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: room.id));
                        _snack('房间号已复制');
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatTile(
                      label: '成员数',
                      value:
                          '${_members.isEmpty ? room.memberCount : _members.length} 人',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('房间成员',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ..._members.map(
                  (member) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      child: Text(
                        member.name.isEmpty
                            ? '?'
                            : member.name.characters.first.toUpperCase(),
                      ),
                    ),
                    title: Text(member.name),
                    trailing: member.isOwner ? const _Badge(text: '房主') : null,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _isOwner
                ? '💡 去播放页或直播页开始观影，房间成员会自动同步你的操作。'
                : '💡 房主开始播放后，你这边会自动跟着同步。',
            style: theme.textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
          ),
          onPressed: _leaveRoom,
          icon: const Icon(Icons.logout),
          label: Text(_isOwner ? '解散房间' : '离开房间'),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.state, required this.onRetry});

  final _ConnectionState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (state) {
      _ConnectionState.connected => ('已连接', Colors.green, Icons.check_circle),
      _ConnectionState.connecting => ('连接中', Colors.orange, Icons.sync),
      _ConnectionState.failed => ('连接失败', Colors.red, Icons.error_outline),
      _ConnectionState.disabled => ('未启用', Colors.grey, Icons.block),
    };
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color, fontSize: 12)),
        if (state != _ConnectionState.connected)
          IconButton(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: '重试',
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFBBF24),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF78350F),
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value, this.onTap});

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
