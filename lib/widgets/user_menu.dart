import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/user_data_service.dart';
import '../screens/login_screen.dart';
import '../services/douban_cache_service.dart';
import '../services/page_cache_service.dart';
import '../services/live_service.dart';
import '../services/local_search_cache_service.dart';
import '../services/version_service.dart';
import '../services/worker_proxy_service.dart';
import '../utils/device_utils.dart';
import '../utils/font_utils.dart';
import '../utils/orientation_utils.dart';
import 'update_dialog.dart';

class UserMenu extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback? onClose;

  const UserMenu({
    super.key,
    required this.isDarkMode,
    this.onClose,
  });

  @override
  State<UserMenu> createState() => _UserMenuState();
}

class _UserMenuState extends State<UserMenu> {
  String? _username;
  String _role = 'user';
  String _doubanDataSource = '直连';
  String _doubanImageSource = '直连';
  String _m3u8ProxyUrl = '';
  String _workerProxyUrl = '';
  String _version = '';
  bool _preferSpeedTest = true;
  bool _localSearch = false;
  bool _isLocalMode = false;
  String _playbackCacheMode = '默认';
  String _landscapeDirection = '向左';

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _version = packageInfo.version;
      });
    }
  }

  Future<void> _loadUserInfo() async {
    final isLocalMode = await UserDataService.getIsLocalMode();
    final username = await UserDataService.getUsername();
    final cookies = await UserDataService.getCookies();
    final doubanDataSource =
        await UserDataService.getDoubanDataSourceDisplayName();
    final doubanImageSource =
        await UserDataService.getDoubanImageSourceDisplayName();
    final m3u8ProxyUrl = await UserDataService.getM3u8ProxyUrl();
    final workerProxyUrl = await UserDataService.getWorkerProxyUrl();
    final preferSpeedTest = await UserDataService.getPreferSpeedTest();
    final localSearch = await UserDataService.getLocalSearch();
    final playbackCacheMode = await UserDataService.getPlaybackCacheMode();
    final landscapeDirection = await UserDataService.getLandscapeDirection();

    if (mounted) {
      setState(() {
        _isLocalMode = isLocalMode;
        _username = username;
        _role = _parseRoleFromCookies(cookies);
        _doubanDataSource = doubanDataSource;
        _doubanImageSource = doubanImageSource;
        _m3u8ProxyUrl = m3u8ProxyUrl;
        _workerProxyUrl = workerProxyUrl;
        _preferSpeedTest = preferSpeedTest;
        _localSearch = localSearch;
        _playbackCacheMode = switch (playbackCacheMode) {
          'enhanced' => '增强',
          'maximum' => '强力',
          _ => '默认',
        };
        _landscapeDirection = landscapeDirection == 'right' ? '向右' : '向左';
      });
    }
  }

  String _parseRoleFromCookies(String? cookies) {
    if (cookies == null || cookies.isEmpty) {
      return 'user';
    }

    try {
      // 解析cookies字符串
      final cookieMap = <String, String>{};
      final cookiePairs = cookies.split(';');

      for (final cookie in cookiePairs) {
        final trimmed = cookie.trim();
        final firstEqualIndex = trimmed.indexOf('=');

        if (firstEqualIndex > 0) {
          final key = trimmed.substring(0, firstEqualIndex);
          final value = trimmed.substring(firstEqualIndex + 1);
          if (key.isNotEmpty && value.isNotEmpty) {
            cookieMap[key] = value;
          }
        }
      }

      final authCookie = cookieMap['auth'];
      if (authCookie == null) {
        return 'user';
      }

      // 处理可能的双重编码
      String decoded = Uri.decodeComponent(authCookie);

      // 如果解码后仍然包含 %，说明是双重编码，需要再次解码
      if (decoded.contains('%')) {
        decoded = Uri.decodeComponent(decoded);
      }

      final authData = json.decode(decoded);
      final role = authData['role'] as String?;

      return role ?? 'user';
    } catch (e) {
      // 解析失败时默认为user
      return 'user';
    }
  }

  Future<void> _handleLogout() async {
    // 清空所有缓存
    LiveService.clearAllCache();
    LocalSearchCacheService().clearCache();
    PageCacheService().clearAllCache();

    // 只清除密码和cookies，保留服务器地址和用户名
    await UserDataService.clearPasswordAndCookies();

    await UserDataService.saveIsLocalMode(false);

    // 跳转到登录页，并移除所有之前的路由（强制销毁所有页面）
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  Future<void> _handleClearDoubanCache() async {
    try {
      await DoubanCacheService().clearAll();
      // 同时清空 Bangumi 的函数级与内存级缓存
      PageCacheService().clearCache('bangumi_calendar');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已清除豆瓣缓存')),
        );
        // 清除后关闭菜单
        widget.onClose?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('清除豆瓣缓存失败')),
        );
        // 即便失败也关闭菜单，避免停留
        widget.onClose?.call();
      }
    }
  }

  Future<void> _handleCheckUpdate() async {
    try {
      // 显示加载提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '正在检查更新...',
              style: FontUtils.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.black,
            duration: const Duration(seconds: 2),
          ),
        );
      }

      final versionInfo = await VersionService.checkForUpdate();

      if (!mounted) return;

      if (versionInfo != null) {
        // 有新版本，显示更新对话框
        await UpdateDialog.show(context, versionInfo);
      } else {
        // 已是最新版本
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '当前已是最新版本',
              style: FontUtils.poppins(color: Colors.white),
            ),
            backgroundColor: const Color(0xFF27AE60),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '检查更新失败: ${e.toString()}',
              style: FontUtils.poppins(color: Colors.white),
            ),
            backgroundColor: const Color(0xFFef4444),
          ),
        );
      }
    }
  }

  Widget _buildRoleTag() {
    String label;
    Color color;

    switch (_role) {
      case 'admin':
        label = '管理员';
        color = const Color(0xFFf59e0b); // 橙黄色
        break;
      case 'owner':
        label = '站长';
        color = const Color(0xFF8b5cf6); // 紫色
        break;
      case 'user':
      default:
        label = '用户';
        color = const Color(0xFF10b981); // 绿色
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: FontUtils.poppins(
          fontSize: 10,
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildOptionSelector({
    required String title,
    required String currentValue,
    required List<String> options,
    required Future<void> Function(String) onChanged,
    required IconData icon,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showOptionDialog(title, currentValue, options, onChanged),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 10,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: FontUtils.poppins(
                        fontSize: 16,
                        color: widget.isDarkMode
                            ? const Color(0xFFffffff)
                            : const Color(0xFF1f2937),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      currentValue,
                      style: FontUtils.poppins(
                        fontSize: 12,
                        color: widget.isDarkMode
                            ? const Color(0xFF9ca3af)
                            : const Color(0xFF6b7280),
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showOptionDialog(String title, String currentValue,
      List<String> options, Future<void> Function(String) onChanged) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor:
              widget.isDarkMode ? const Color(0xFF2c2c2c) : Colors.white,
          title: Text(
            title,
            style: FontUtils.poppins(
              fontSize: 18,
              color: widget.isDarkMode
                  ? const Color(0xFFffffff)
                  : const Color(0xFF1f2937),
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: options.map((option) {
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () async {
                    await onChanged(option);
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 16,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          currentValue == option
                              ? LucideIcons.check
                              : LucideIcons.circle,
                          size: 20,
                          color: currentValue == option
                              ? const Color(0xFF10b981)
                              : (widget.isDarkMode
                                  ? const Color(0xFF9ca3af)
                                  : const Color(0xFF6b7280)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            option,
                            style: FontUtils.poppins(
                              fontSize: 16,
                              color: widget.isDarkMode
                                  ? const Color(0xFFffffff)
                                  : const Color(0xFF1f2937),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }

  /// Cloudflare Worker 代理加速：地址 + 功能说明。
  void _showWorkerProxyDialog() {
    final controller = TextEditingController(text: _workerProxyUrl);
    final textColor =
        widget.isDarkMode ? const Color(0xFFffffff) : const Color(0xFF1f2937);
    final mutedColor =
        widget.isDarkMode ? const Color(0xFF9ca3af) : const Color(0xFF6b7280);
    const features = [
      '通过 Cloudflare 全球 CDN 加速视频源 API 访问',
      '自动转发所有 API 参数（ac=list、ac=detail 等）',
      '为每个源生成唯一路径，提升兼容性',
      '播放 m3u8/视频时自动经 Worker 代理转发，加速播放流',
      'Worker 代理失败时自动降级为直连，不影响正常播放',
      'Emby 源不受影响（需自定义鉴权头，始终直连）',
      '仅影响 App 内播放，不影响 TVBox 配置',
    ];

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor:
              widget.isDarkMode ? const Color(0xFF2c2c2c) : Colors.white,
          title: Text(
            'Cloudflare Worker 代理加速',
            style: FontUtils.poppins(
              fontSize: 18,
              color: textColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.url,
                  style: FontUtils.poppins(fontSize: 14, color: textColor),
                  decoration: InputDecoration(
                    hintText: '例如 https://your-worker.workers.dev',
                    hintStyle:
                        FontUtils.poppins(fontSize: 14, color: mutedColor),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: widget.isDarkMode
                            ? const Color(0xFF374151)
                            : const Color(0xFFe5e7eb),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: widget.isDarkMode
                            ? const Color(0xFF374151)
                            : const Color(0xFFe5e7eb),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: Color(0xFF10b981),
                        width: 2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '💡 功能说明',
                  style: FontUtils.poppins(
                    fontSize: 14,
                    color: textColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ...features.map(
                  (feature) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('• ',
                            style: FontUtils.poppins(
                                fontSize: 12, color: mutedColor)),
                        Expanded(
                          child: Text(
                            feature,
                            style: FontUtils.poppins(
                                fontSize: 12, color: mutedColor, height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                '取消',
                style: FontUtils.poppins(fontSize: 14, color: mutedColor),
              ),
            ),
            TextButton(
              onPressed: () async {
                final url = controller.text.trim();
                await UserDataService.saveWorkerProxyUrl(url);
                WorkerProxyService.resetHealthCache();
                if (!mounted) return;
                setState(
                    () => _workerProxyUrl = url.replaceAll(RegExp(r'/+$'), ''));
                if (context.mounted) Navigator.of(context).pop();
              },
              child: Text(
                '保存',
                style: FontUtils.poppins(
                  fontSize: 14,
                  color: const Color(0xFF10b981),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    ).whenComplete(controller.dispose);
  }

  void _showM3u8ProxyUrlDialog() {
    final controller = TextEditingController(text: _m3u8ProxyUrl);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor:
              widget.isDarkMode ? const Color(0xFF2c2c2c) : Colors.white,
          title: Text(
            'M3U8 代理 URL',
            style: FontUtils.poppins(
              fontSize: 18,
              color: widget.isDarkMode
                  ? const Color(0xFFffffff)
                  : const Color(0xFF1f2937),
              fontWeight: FontWeight.w600,
            ),
          ),
          content: TextField(
            controller: controller,
            style: FontUtils.poppins(
              fontSize: 14,
              color: widget.isDarkMode
                  ? const Color(0xFFffffff)
                  : const Color(0xFF1f2937),
            ),
            decoration: InputDecoration(
              hintText: '输入代理 URL（可选）',
              hintStyle: FontUtils.poppins(
                fontSize: 14,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                  color: widget.isDarkMode
                      ? const Color(0xFF374151)
                      : const Color(0xFFe5e7eb),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                  color: widget.isDarkMode
                      ? const Color(0xFF374151)
                      : const Color(0xFFe5e7eb),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(
                  color: Color(0xFF10b981),
                  width: 2,
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(
                '取消',
                style: FontUtils.poppins(
                  fontSize: 14,
                  color: widget.isDarkMode
                      ? const Color(0xFF9ca3af)
                      : const Color(0xFF6b7280),
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                final url = controller.text.trim();
                await UserDataService.saveM3u8ProxyUrl(url);
                if (!mounted) return;
                setState(() {
                  _m3u8ProxyUrl = url;
                });
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: Text(
                '保存',
                style: FontUtils.poppins(
                  fontSize: 14,
                  color: const Color(0xFF10b981),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    ).whenComplete(controller.dispose);
  }

  Widget _buildInputOption({
    required String title,
    required String currentValue,
    required VoidCallback onTap,
    required IconData icon,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 10,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: FontUtils.poppins(
                        fontSize: 16,
                        color: widget.isDarkMode
                            ? const Color(0xFFffffff)
                            : const Color(0xFF1f2937),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      currentValue.isEmpty ? '未设置' : currentValue,
                      style: FontUtils.poppins(
                        fontSize: 12,
                        color: widget.isDarkMode
                            ? const Color(0xFF9ca3af)
                            : const Color(0xFF6b7280),
                        fontWeight: FontWeight.w400,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToggleOption({
    required String title,
    required bool value,
    required Future<void> Function(bool) onChanged,
    required IconData icon,
  }) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 10,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: widget.isDarkMode
                  ? const Color(0xFF9ca3af)
                  : const Color(0xFF6b7280),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: FontUtils.poppins(
                  fontSize: 16,
                  color: widget.isDarkMode
                      ? const Color(0xFFffffff)
                      : const Color(0xFF1f2937),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            GestureDetector(
              onTap: () async {
                await onChanged(!value);
                if (!mounted) return;
                setState(() {});
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 44,
                height: 24,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: value
                      ? const Color(0xFF10b981)
                      : (widget.isDarkMode
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb)),
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 200),
                  alignment:
                      value ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: 20,
                    height: 20,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: widget.onClose,
        child: Container(
          color: Colors.black.withOpacity(0.3),
          child: Center(
            child: GestureDetector(
              onTap: () {}, // 阻止点击菜单内容时关闭
              child: Container(
                width: 280,
                margin: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: widget.isDarkMode
                      ? const Color(0xFF2c2c2c)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 用户信息区域
                    Container(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          // 本地模式下不显示"当前模式"标签
                          if (!_isLocalMode)
                            Text(
                              '当前用户',
                              style: FontUtils.poppins(
                                fontSize: 12,
                                color: widget.isDarkMode
                                    ? const Color(0xFF9ca3af)
                                    : const Color(0xFF6b7280),
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          if (!_isLocalMode) const SizedBox(height: 8),
                          // 用户名或本地模式
                          if (_isLocalMode)
                            Text(
                              '本地模式',
                              style: FontUtils.poppins(
                                fontSize: 18,
                                color: widget.isDarkMode
                                    ? const Color(0xFFffffff)
                                    : const Color(0xFF1f2937),
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          else
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  _username ?? '未知用户',
                                  style: FontUtils.poppins(
                                    fontSize: 18,
                                    color: widget.isDarkMode
                                        ? const Color(0xFFffffff)
                                        : const Color(0xFF1f2937),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // 角色标签
                                _buildRoleTag(),
                              ],
                            ),
                        ],
                      ),
                    ),
                    // 分割线
                    Container(
                      height: 1,
                      color: widget.isDarkMode
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb),
                    ),
                    // 豆瓣数据源选项
                    _buildOptionSelector(
                      title: '豆瓣数据源',
                      currentValue: _doubanDataSource,
                      options: const [
                        '直连',
                        'Cors Proxy By Zwei',
                        '豆瓣 CDN By CMLiussss（腾讯云）',
                        '豆瓣 CDN By CMLiussss（阿里云）',
                      ],
                      onChanged: (value) async {
                        await UserDataService.saveDoubanDataSource(value);
                        if (!mounted) return;
                        setState(() {
                          _doubanDataSource = value;
                        });
                      },
                      icon: LucideIcons.database,
                    ),
                    // 分割线
                    Container(
                      height: 1,
                      color: widget.isDarkMode
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb),
                    ),
                    // 豆瓣图片源选项
                    _buildOptionSelector(
                      title: '豆瓣图片源',
                      currentValue: _doubanImageSource,
                      options: const [
                        '直连',
                        '豆瓣官方精品 CDN',
                        '豆瓣 CDN By CMLiussss（腾讯云）',
                        '豆瓣 CDN By CMLiussss（阿里云）',
                      ],
                      onChanged: (value) async {
                        await UserDataService.saveDoubanImageSource(value);
                        if (!mounted) return;
                        setState(() {
                          _doubanImageSource = value;
                        });
                      },
                      icon: LucideIcons.image,
                    ),
                    // 分割线
                    Container(
                      height: 1,
                      color: widget.isDarkMode
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb),
                    ),
                    // M3U8 代理 URL 选项
                    _buildInputOption(
                      title: 'M3U8 代理 URL',
                      currentValue: _m3u8ProxyUrl,
                      onTap: _showM3u8ProxyUrlDialog,
                      icon: LucideIcons.link,
                    ),
                    // 分割线
                    Container(
                      height: 1,
                      color: widget.isDarkMode
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb),
                    ),
                    // Cloudflare Worker 代理加速
                    _buildInputOption(
                      title: 'Cloudflare Worker 代理加速',
                      currentValue: _workerProxyUrl,
                      onTap: _showWorkerProxyDialog,
                      icon: LucideIcons.cloud,
                    ),
                    // 分割线
                    Container(
                      height: 1,
                      color: widget.isDarkMode
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb),
                    ),
                    // 优选测速选项
                    _buildToggleOption(
                      title: '优选测速',
                      value: _preferSpeedTest,
                      onChanged: (value) async {
                        await UserDataService.savePreferSpeedTest(value);
                        if (!mounted) return;
                        setState(() {
                          _preferSpeedTest = value;
                        });
                      },
                      icon: LucideIcons.zap,
                    ),
                    Container(
                      height: 1,
                      color: widget.isDarkMode
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb),
                    ),
                    _buildOptionSelector(
                      title: '播放缓存优化',
                      currentValue: _playbackCacheMode,
                      options: const ['默认', '增强', '强力'],
                      onChanged: (value) async {
                        final mode = switch (value) {
                          '增强' => 'enhanced',
                          '强力' => 'maximum',
                          _ => 'default',
                        };
                        await UserDataService.savePlaybackCacheMode(mode);
                        if (!mounted) return;
                        setState(() => _playbackCacheMode = value);
                      },
                      icon: LucideIcons.gauge,
                    ),
                    Container(
                      height: 1,
                      color: widget.isDarkMode
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb),
                    ),
                    // 全屏方向固定成单一方向，避免系统按重力选反导致画面倒置。
                    _buildOptionSelector(
                      title: '全屏方向',
                      currentValue: _landscapeDirection,
                      options: const ['向左', '向右'],
                      onChanged: (value) async {
                        final direction = value == '向右' ? 'right' : 'left';
                        await UserDataService.saveLandscapeDirection(direction);
                        OrientationUtils.setDirection(
                          LandscapeDirection.fromName(direction),
                        );
                        if (!mounted) return;
                        setState(() => _landscapeDirection = value);
                      },
                      icon: LucideIcons.rotateCw,
                    ),
                    // 本地搜索选项（本地模式下不显示）
                    if (!_isLocalMode) ...[
                      // 分割线
                      Container(
                        height: 1,
                        color: widget.isDarkMode
                            ? const Color(0xFF374151)
                            : const Color(0xFFe5e7eb),
                      ),
                      _buildToggleOption(
                        title: '本地搜索',
                        value: _localSearch,
                        onChanged: (value) async {
                          await UserDataService.saveLocalSearch(value);
                          if (!mounted) return;
                          setState(() {
                            _localSearch = value;
                          });
                        },
                        icon: LucideIcons.search,
                      ),
                    ],
                    // 分割线
                    Container(
                      height: 1,
                      color: widget.isDarkMode
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb),
                    ),
                    // 清除豆瓣缓存按钮
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _handleClearDoubanCache,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                LucideIcons.trash2,
                                size: 20,
                                color: const Color(0xFFf59e0b),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                '清除豆瓣缓存',
                                style: FontUtils.poppins(
                                  fontSize: 16,
                                  color: widget.isDarkMode
                                      ? const Color(0xFFffffff)
                                      : const Color(0xFF1f2937),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // 分割线
                    Container(
                      height: 1,
                      color: widget.isDarkMode
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb),
                    ),
                    // 检查更新按钮
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _handleCheckUpdate,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                LucideIcons.download,
                                size: 20,
                                color: const Color(0xFF3b82f6),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                '检查更新',
                                style: FontUtils.poppins(
                                  fontSize: 16,
                                  color: widget.isDarkMode
                                      ? const Color(0xFFffffff)
                                      : const Color(0xFF1f2937),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // 分割线
                    Container(
                      height: 1,
                      color: widget.isDarkMode
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb),
                    ),
                    // 登出按钮
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _handleLogout,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                LucideIcons.logOut,
                                size: 20,
                                color: Color(0xFFef4444),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                '登出',
                                style: FontUtils.poppins(
                                  fontSize: 16,
                                  color: const Color(0xFFef4444),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // 分割线
                    Container(
                      height: 1,
                      color: widget.isDarkMode
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb),
                    ),
                    // 版本号
                    MouseRegion(
                      cursor: DeviceUtils.isPC()
                          ? SystemMouseCursors.click
                          : MouseCursor.defer,
                      child: GestureDetector(
                        onTap: () async {
                          final url = Uri.parse(
                              'https://github.com/MoonTechLab/Selene');
                          if (await canLaunchUrl(url)) {
                            await launchUrl(url,
                                mode: LaunchMode.externalApplication);
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          child: Center(
                            child: Text(
                              _version.isEmpty ? 'v1.4.3' : 'v$_version',
                              style: FontUtils.poppins(
                                fontSize: 14,
                                color: widget.isDarkMode
                                    ? const Color(0xFF9ca3af)
                                    : const Color(0xFF6b7280),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
