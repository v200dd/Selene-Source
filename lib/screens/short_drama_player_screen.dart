import 'package:flutter/material.dart';
import '../services/short_drama_service.dart';
import '../utils/device_utils.dart';
import '../utils/font_utils.dart';
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
    _loadEpisode(1);
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
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: _buildPlayerArea(url),
            ),
            Expanded(child: _buildEpisodeList()),
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
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: FontUtils.poppins(color: Colors.white, fontSize: 13)),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _loadEpisode(_episode),
                child: const Text('重试'),
              ),
            ],
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

  Widget _buildEpisodeList() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.item.name,
            style: FontUtils.poppins(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: GridView.builder(
              itemCount: _totalEpisodes,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 1.8,
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
                          : Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$episode',
                      style:
                          FontUtils.poppins(color: Colors.white, fontSize: 13),
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
