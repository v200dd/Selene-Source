import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/short_drama_service.dart';
import '../services/theme_service.dart';
import '../utils/device_utils.dart';
import '../utils/font_utils.dart';
import '../utils/orientation_utils.dart';
import '../widgets/video_player_surface.dart';
import '../widgets/video_player_widget.dart';

/// 短剧播放页。短剧的播放地址需要通过 `/api/shortdrama/parse` 逐集解析，
/// 与常规影视的聚合搜索流程不同，因此单独一个页面。
class ShortDramaPlayerScreen extends StatefulWidget {
  const ShortDramaPlayerScreen({super.key, required this.item});

  final ShortDramaItem item;

  @override
  State<ShortDramaPlayerScreen> createState() => _ShortDramaPlayerScreenState();
}

class _ShortDramaPlayerScreenState extends State<ShortDramaPlayerScreen> {
  VideoPlayerWidgetController? _controller;
  String? _url;
  String? _error;
  bool _loading = true;
  int _episode = 1;
  int _totalEpisodes = 1;

  @override
  void initState() {
    super.initState();
    _totalEpisodes =
        widget.item.episodeCount < 1 ? 1 : widget.item.episodeCount;
    // 跟常规播放页一致：放开旋转但不强制横屏，两个方向的横屏都允许。
    OrientationUtils.allowPlaybackRotation();
    _loadEpisode(1);
    _refreshEpisodeCount();
  }

  /// `/api/shortdrama/parse` 在主采集源失效时会把总集数退化成 1，
  /// 这里再向 `/api/shortdrama/detail`（内部会走备用 API）取一次较大的值。
  Future<void> _refreshEpisodeCount() async {
    try {
      final count = await ShortDramaService.getEpisodeCount(
        id: widget.item.id,
        name: widget.item.name,
      );
      if (!mounted || count <= _totalEpisodes) return;
      setState(() => _totalEpisodes = count);
    } catch (_) {
      // 集数只是展示优化，取不到就保持现状。
    }
  }

  Future<void> _loadEpisode(int episode) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ShortDramaService.parseEpisode(
        id: widget.item.id,
        episode: episode,
        name: widget.item.name,
      );
      if (!mounted) return;
      setState(() {
        _episode = result.episode;
        _totalEpisodes =
            result.totalEpisodes > 1 ? result.totalEpisodes : _totalEpisodes;
        _url = result.url;
        _loading = false;
      });
      await _controller?.updateDataSource(result.url);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is ShortDramaException
            ? error.friendlyMessage
            : error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  void dispose() {
    // 退出播放页恢复竖屏。
    OrientationUtils.lockPortrait();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    final isDark = Provider.of<ThemeService>(context).isDarkMode;
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF141414) : Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: _buildPlayerArea(url),
            ),
            Expanded(child: _buildEpisodeList(isDark)),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerArea(String? url) {
    if (_error != null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_error!,
                    textAlign: TextAlign.center,
                    style: FontUtils.poppins(
                        color: Colors.white, fontSize: 13, height: 1.5)),
                const SizedBox(height: 6),
                Text(
                  _hintFor(_error!),
                  textAlign: TextAlign.center,
                  style: FontUtils.poppins(
                      color: Colors.white54, fontSize: 11, height: 1.5),
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () => _loadEpisode(_episode),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (url == null || _loading) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return VideoPlayerWidget(
      key: ValueKey('${widget.item.id}-$_episode'),
      surface: DeviceUtils.isPC()
          ? VideoPlayerSurface.desktop
          : VideoPlayerSurface.mobile,
      url: url,
      videoTitle: widget.item.name,
      currentEpisodeIndex: _episode - 1,
      totalEpisodes: _totalEpisodes,
      sourceName: '短剧',
      isLastEpisode: _episode >= _totalEpisodes,
      onBackPressed: () => Navigator.of(context).pop(),
      onControllerCreated: (controller) => _controller = controller,
      onNextEpisode:
          _episode < _totalEpisodes ? () => _loadEpisode(_episode + 1) : null,
    );
  }

  /// 给服务端返回的错误补一句能落地的处理建议。
  String _hintFor(String error) {
    if (error.contains('网络连接失败')) {
      return '这句提示来自你的主站，说明主站访问上游短剧源失败。\n请在后台更换短剧采集源或启用备用 API 后重试。';
    }
    if (error.contains('没有短剧接口')) {
      return '需要升级 LunaTV / MoonTV 到带短剧模块的版本。';
    }
    if (error.contains('登录已过期')) {
      return '回到「我的」重新登录即可。';
    }
    return '如果反复失败，多为主站短剧采集源不可用。';
  }

  Widget _buildEpisodeList(bool isDark) {
    final textColor = isDark ? Colors.white : const Color(0xFF2c3e50);
    final subColor = isDark ? Colors.white54 : const Color(0xFF7f8c8d);
    return Container(
      color: isDark ? const Color(0xFF141414) : Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: FontUtils.poppins(
                color: textColor, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            _totalEpisodes > 1
                ? '共 $_totalEpisodes 集 · 正在播放第 $_episode 集'
                : '正在播放第 $_episode 集（主站未返回总集数）',
            style: FontUtils.poppins(color: subColor, fontSize: 11),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: _totalEpisodes,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.7,
              ),
              itemBuilder: (context, index) {
                final episode = index + 1;
                final selected = episode == _episode;
                return GestureDetector(
                  onTap: selected ? null : () => _loadEpisode(episode),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF27ae60)
                          : (isDark
                              ? Colors.white.withValues(alpha: 0.08)
                              : const Color(0xFFf1f3f4)),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected
                            ? const Color(0xFF27ae60)
                            : (isDark
                                ? Colors.white.withValues(alpha: 0.08)
                                : const Color(0xFFe4e7e9)),
                      ),
                    ),
                    child: Text(
                      '$episode',
                      style: FontUtils.poppins(
                        color: selected ? Colors.white : textColor,
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
