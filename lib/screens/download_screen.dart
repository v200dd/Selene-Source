import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../services/download_service.dart';
import '../services/hls_downloader.dart';
import '../services/theme_service.dart';
import '../utils/device_utils.dart';
import '../utils/font_utils.dart';
import '../widgets/video_player_surface.dart';
import '../widgets/video_player_widget.dart';

/// 本地下载分类页：列出已下载/正在下载的视频，可播放、重试、删除。
class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  @override
  void initState() {
    super.initState();
    DownloadService.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    final themeService = Provider.of<ThemeService>(context);
    final isDark = themeService.isDarkMode;

    return ValueListenableBuilder<List<DownloadTask>>(
      valueListenable: DownloadService.instance.tasks,
      builder: (context, tasks, _) {
        if (tasks.isEmpty) return _buildEmpty(isDark);
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          itemCount: tasks.length + 1,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) => index == 0
              ? _buildInfoCard(isDark)
              : _buildCard(tasks[index - 1], isDark),
        );
      },
    );
  }

  /// M3U8 客户端下载能力说明。
  Widget _buildInfoCard(bool isDark) {
    const features = [
      '在设备本机直接下载视频，不占用服务器存储和带宽',
      '支持 M3U8 的 TS 片段合并，可选 TS 或 MP4 输出',
      '支持 AES-128 加密视频自动解密',
      '并发下载 + 失败自动重试，已下好的片段不会重复下载',
    ];
    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF27ae60).withValues(alpha: 0.1)
            : const Color(0xFF27ae60).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(LucideIcons.info, size: 14, color: Color(0xFF27ae60)),
              const SizedBox(width: 6),
              Text(
                'M3U8 客户端下载',
                style: FontUtils.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF27ae60),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...features.map((feature) => Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  '• $feature',
                  style: FontUtils.poppins(
                    fontSize: 11,
                    height: 1.5,
                    color: isDark
                        ? const Color(0xFFaaaaaa)
                        : const Color(0xFF7f8c8d),
                  ),
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildEmpty(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.download,
            size: 48,
            color: isDark ? const Color(0xFF555555) : const Color(0xFFbdc3c7),
          ),
          const SizedBox(height: 16),
          Text(
            '还没有下载内容',
            style: FontUtils.poppins(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: isDark ? const Color(0xFFdddddd) : const Color(0xFF2c3e50),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              '在播放页点下载按钮即可离线保存。\n'
              'M3U8 会在本机下载 TS 片段、自动解密并合并，可选 TS 或 MP4。',
              textAlign: TextAlign.center,
              style: FontUtils.poppins(
                fontSize: 12,
                height: 1.6,
                color:
                    isDark ? const Color(0xFF999999) : const Color(0xFF7f8c8d),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(DownloadTask task, bool isDark) {
    final subtitle = _subtitleFor(task);
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF333333) : const Color(0xFFe6e6e6),
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildThumb(task, isDark),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: FontUtils.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? const Color(0xFFffffff)
                        : const Color(0xFF2c3e50),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: FontUtils.poppins(
                    fontSize: 11,
                    color: task.status == DownloadStatus.failed
                        ? const Color(0xFFe74c3c)
                        : (isDark
                            ? const Color(0xFF999999)
                            : const Color(0xFF7f8c8d)),
                  ),
                ),
                if (task.status == DownloadStatus.running ||
                    task.status == DownloadStatus.queued) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: task.isSegmented || task.totalBytes > 0
                          ? task.progress
                          : null,
                      minHeight: 4,
                      backgroundColor: isDark
                          ? const Color(0xFF333333)
                          : const Color(0xFFecf0f1),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFF27ae60),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: _buildActions(task, isDark),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThumb(DownloadTask task, bool isDark) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 72,
        height: 96,
        color: isDark ? const Color(0xFF2a2a2a) : const Color(0xFFecf0f1),
        child: task.poster.isEmpty
            ? Icon(
                LucideIcons.film,
                size: 22,
                color:
                    isDark ? const Color(0xFF666666) : const Color(0xFFbdc3c7),
              )
            : Image.network(
                task.poster,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(
                  LucideIcons.film,
                  size: 22,
                  color: isDark
                      ? const Color(0xFF666666)
                      : const Color(0xFFbdc3c7),
                ),
              ),
      ),
    );
  }

  String _subtitleFor(DownloadTask task) {
    switch (task.status) {
      case DownloadStatus.completed:
        return '已下载 · ${task.format.label} · '
            '${DownloadService.formatBytes(task.totalBytes)}';
      case DownloadStatus.running:
        if (task.isSegmented) {
          return '下载分片 ${task.doneSegments}/${task.totalSegments} · '
              '${DownloadService.formatBytes(task.receivedBytes)}';
        }
        final total = task.totalBytes > 0
            ? ' / ${DownloadService.formatBytes(task.totalBytes)}'
            : '';
        return '下载中 ${DownloadService.formatBytes(task.receivedBytes)}$total';
      case DownloadStatus.queued:
        return '排队中';
      case DownloadStatus.paused:
        if (task.isSegmented) {
          return '已暂停 · 分片 ${task.doneSegments}/${task.totalSegments}'
              '（重试会跳过已下好的片段）';
        }
        return '已暂停 · ${DownloadService.formatBytes(task.receivedBytes)}';
      case DownloadStatus.failed:
        return '下载失败：${task.error ?? '未知错误'}';
    }
  }

  List<Widget> _buildActions(DownloadTask task, bool isDark) {
    final actions = <Widget>[];

    if (task.status == DownloadStatus.completed) {
      actions.add(_buildAction(
        icon: LucideIcons.play,
        label: '播放',
        primary: true,
        onTap: () => _play(task),
      ));
    } else if (task.status == DownloadStatus.running) {
      actions.add(_buildAction(
        icon: LucideIcons.pause,
        label: '暂停',
        onTap: () => DownloadService.instance.cancel(task),
        isDark: isDark,
      ));
    } else {
      actions.add(_buildAction(
        icon: LucideIcons.refreshCw,
        label: '重试',
        onTap: () => DownloadService.instance.retry(task),
        isDark: isDark,
      ));
    }

    actions.add(const SizedBox(width: 8));
    actions.add(_buildAction(
      icon: LucideIcons.trash2,
      label: '删除',
      danger: true,
      onTap: () => _confirmRemove(task),
      isDark: isDark,
    ));
    return actions;
  }

  Widget _buildAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool primary = false,
    bool danger = false,
    bool isDark = false,
  }) {
    final color = primary
        ? const Color(0xFF27ae60)
        : danger
            ? const Color(0xFFe74c3c)
            : (isDark ? const Color(0xFFcccccc) : const Color(0xFF7f8c8d));
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: FontUtils.poppins(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(DownloadTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除下载'),
        content: Text('确定删除「${task.displayTitle}」及其本地文件吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await DownloadService.instance.remove(task);
    }
  }

  Future<void> _play(DownloadTask task) async {
    final file = await DownloadService.instance.fileForTask(task);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地文件已丢失，请重新下载')),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => _LocalPlaybackScreen(
          title: task.displayTitle,
          file: file,
        ),
      ),
    );
  }
}

/// 本地文件播放页，直接把本地路径交给播放器。
class _LocalPlaybackScreen extends StatelessWidget {
  const _LocalPlaybackScreen({required this.title, required this.file});

  final String title;
  final File file;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: VideoPlayerWidget(
          surface: DeviceUtils.isPC()
              ? VideoPlayerSurface.desktop
              : VideoPlayerSurface.mobile,
          url: file.path,
          videoTitle: title,
          sourceName: '本地下载',
          onBackPressed: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }
}
