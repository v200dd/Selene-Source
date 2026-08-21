import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pip/pip.dart';
import '../models/danmaku_comment.dart';
import '../services/danmaku_service.dart';
import '../services/download_service.dart';
import '../services/user_data_service.dart';
import 'danmaku_overlay.dart';
import 'mobile_player_controls.dart';
import 'pc_player_controls.dart';
import 'video_player_surface.dart';

class VideoPlayerWidget extends StatefulWidget {
  final VideoPlayerSurface surface;
  final String? url;
  final Map<String, String>? headers;
  final VoidCallback? onBackPressed;
  final Function(VideoPlayerWidgetController)? onControllerCreated;
  final VoidCallback? onReady;
  final VoidCallback? onNextEpisode;
  final VoidCallback? onVideoCompleted;
  final VoidCallback? onPause;
  final bool isLastEpisode;
  final Function(dynamic)? onCastStarted;
  final String? videoTitle;
  final int? currentEpisodeIndex;
  final int? totalEpisodes;
  final String? sourceName;
  final Function(bool isWebFullscreen)? onWebFullscreenChanged;
  final VoidCallback? onExitFullScreen;
  final bool live;
  final Function(bool isPipMode)? onPipModeChanged;

  /// 弹幕匹配用（主站 `/api/danmu-external` 会用它提高命中率）。
  final String? doubanId;
  final String? year;

  const VideoPlayerWidget({
    super.key,
    this.surface = VideoPlayerSurface.mobile,
    this.url,
    this.headers,
    this.onBackPressed,
    this.onControllerCreated,
    this.onReady,
    this.onNextEpisode,
    this.onVideoCompleted,
    this.onPause,
    this.isLastEpisode = false,
    this.onCastStarted,
    this.videoTitle,
    this.currentEpisodeIndex,
    this.totalEpisodes,
    this.sourceName,
    this.onWebFullscreenChanged,
    this.onExitFullScreen,
    this.live = false,
    this.onPipModeChanged,
    this.doubanId,
    this.year,
  });

  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class VideoPlayerWidgetController {
  VideoPlayerWidgetController._(this._state);
  final _VideoPlayerWidgetState _state;

  Future<void> updateDataSource(
    String url, {
    Duration? startAt,
    Map<String, String>? headers,
  }) async {
    await _state._updateDataSource(
      url,
      startAt: startAt,
      headers: headers,
    );
  }

  Future<void> seekTo(Duration position) async {
    await _state._player?.seek(position);
  }

  Duration? get currentPosition => _state._player?.state.position;

  Duration? get duration => _state._player?.state.duration;

  bool get isPlaying => _state._player?.state.playing ?? false;

  Future<void> pause() async {
    await _state._player?.pause();
  }

  Future<void> play() async {
    await _state._player?.play();
  }

  void addProgressListener(VoidCallback listener) {
    _state._addProgressListener(listener);
  }

  void removeProgressListener(VoidCallback listener) {
    _state._removeProgressListener(listener);
  }

  Future<void> setSpeed(double speed) async {
    await _state._setPlaybackSpeed(speed);
  }

  double get playbackSpeed => _state._playbackSpeed.value;

  Future<void> setVolume(double volume) async {
    await _state._player?.setVolume(volume);
  }

  double? get volume => _state._player?.state.volume;

  void exitWebFullscreen() {
    _state._exitWebFullscreen();
  }

  Future<void> dispose() async {
    await _state._externalDispose();
  }

  bool get isPipMode => _state._isPipMode;
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget>
    with WidgetsBindingObserver {
  Player? _player;
  VideoController? _videoController;
  bool _isInitialized = false;
  bool _hasCompleted = false;
  bool _isLoadingVideo = false;
  String? _currentUrl;
  Map<String, String>? _currentHeaders;
  final List<VoidCallback> _progressListeners = [];
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  final ValueNotifier<double> _playbackSpeed = ValueNotifier<double>(1.0);
  bool _playerDisposed = false;
  VoidCallback? _exitWebFullscreenCallback;
  final Pip _pip = Pip();
  static const MethodChannel _iosPipChannel = MethodChannel('selene/ios_pip');
  bool _isPipMode = false;
  bool _pipTransitionInProgress = false;
  bool _danmakuEnabled = true;
  bool _isLoadingDanmaku = false;
  String? _danmakuError;
  String? _danmakuSource;
  final List<DanmakuItem> _danmakuItems = [];
  int _nextDanmakuId = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentUrl = widget.url;
    _currentHeaders = widget.headers;
    _initializePlayer();
    _setupPip();
    _registerPipObserver();
    _registerIosPipHandler();
    _loadDanmakuPreference();
    widget.onControllerCreated?.call(VideoPlayerWidgetController._(this));
  }

  @override
  void didUpdateWidget(covariant VideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.headers != oldWidget.headers && widget.headers != null) {
      _currentHeaders = widget.headers;
    }
    if (widget.url != oldWidget.url && widget.url != null) {
      unawaited(_updateDataSource(widget.url!));
    }
  }

  Future<void> _initializePlayer() async {
    if (_playerDisposed) {
      return;
    }
    final bufferSize = await UserDataService.getPlaybackBufferSize();
    if (_playerDisposed) return;
    _player =
        Player(configuration: PlayerConfiguration(bufferSize: bufferSize));
    _videoController = VideoController(_player!);
    _setupPlayerListeners();
    if (_currentUrl != null) {
      await _openCurrentMedia();
    }
    if (!mounted || _playerDisposed) return;
    setState(() {
      _isInitialized = true;
    });
  }

  Future<void> _openCurrentMedia({Duration? startAt}) async {
    if (_playerDisposed || _player == null || _currentUrl == null) {
      return;
    }
    setState(() {
      _isLoadingVideo = true;
    });
    try {
      await _player!.open(
        Media(
          _currentUrl!,
          start: startAt,
          httpHeaders: _currentHeaders ?? const <String, String>{},
        ),
        play: true,
      );
      await _applyVideoOrientationFix();
      unawaited(_loadDanmaku());
      if (!mounted || _playerDisposed || _player == null) return;
      await _player!.setRate(_playbackSpeed.value);
      if (!mounted || _playerDisposed) return;
      setState(() {
        _hasCompleted = false;
        // _isLoadingVideo = false;
      });
      // widget.onReady?.call();
    } catch (error) {
      debugPrint('VideoPlayerWidget: failed to open media $error');
      if (mounted) {
        setState(() {
          _isLoadingVideo = false;
        });
      }
    }
  }

  void _setupPlayerListeners() {
    if (_player == null) {
      return;
    }
    _positionSubscription?.cancel();
    _playingSubscription?.cancel();
    _completedSubscription?.cancel();
    _durationSubscription?.cancel();

    _positionSubscription = _player!.stream.position.listen((_) {
      for (final listener in List<VoidCallback>.from(_progressListeners)) {
        try {
          listener();
        } catch (error) {
          debugPrint('VideoPlayerWidget: progress listener error $error');
        }
      }
    });

    _playingSubscription = _player!.stream.playing.listen((playing) {
      if (!mounted) return;
      if (!playing) {
        setState(() {
          _hasCompleted = false;
        });
      }
    });

    if (!widget.live) {
      _completedSubscription = _player!.stream.completed.listen((completed) {
        if (!mounted) return;
        if (completed && !_hasCompleted) {
          _hasCompleted = true;
          widget.onVideoCompleted?.call();
        }
      });
    }

    _durationSubscription = _player!.stream.duration.listen((duration) {
      if (!mounted) return;
      if (duration != Duration.zero) {
        if (_isLoadingVideo) {
          setState(() {
            _isLoadingVideo = false;
          });
        }
        widget.onReady?.call();
      }
    });
  }

  Future<void> _updateDataSource(
    String url, {
    Duration? startAt,
    Map<String, String>? headers,
  }) async {
    if (_playerDisposed) {
      return;
    }
    _currentUrl = url;
    _danmakuItems.clear();
    if (headers != null) {
      _currentHeaders = headers;
    }

    if (_player == null) {
      await _initializePlayer();
      return;
    }

    setState(() {
      _isLoadingVideo = true;
    });

    try {
      final currentSpeed = _player!.state.rate;
      await _player!.open(
        Media(
          url,
          start: startAt,
          httpHeaders: _currentHeaders ?? const <String, String>{},
        ),
        play: true,
      );
      await _applyVideoOrientationFix();
      unawaited(_loadDanmaku());
      _playbackSpeed.value = currentSpeed;
      await _player!.setRate(currentSpeed);
      if (mounted) {
        setState(() {
          _hasCompleted = false;
          // _isLoadingVideo = false;
        });
      }
      // widget.onReady?.call();
    } catch (error) {
      debugPrint('VideoPlayerWidget: error while changing source $error');
      if (mounted) {
        setState(() {
          _isLoadingVideo = false;
        });
      }
    }
  }

  void _addProgressListener(VoidCallback listener) {
    if (!_progressListeners.contains(listener)) {
      _progressListeners.add(listener);
    }
  }

  void _removeProgressListener(VoidCallback listener) {
    _progressListeners.remove(listener);
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    _playbackSpeed.value = speed;
    await _player?.setRate(speed);
  }

  Future<void> _applyVideoOrientationFix() async {
    final platform = _player?.platform;
    if (platform is NativePlayer) {
      try {
        // Some providers incorrectly mark the stream as rotated 180 degrees.
        // Keep device orientation free while neutralising that video metadata.
        await platform.setProperty('video-rotate', '0');
      } catch (error) {
        debugPrint('VideoPlayerWidget: unable to reset video rotation: $error');
      }
    }
  }

  Future<void> _loadDanmakuPreference() async {
    final enabled = await UserDataService.getDanmakuEnabled();
    if (mounted) setState(() => _danmakuEnabled = enabled);
  }

  Future<void> _loadDanmaku({bool bypassCache = false}) async {
    final url = _currentUrl;
    final title = widget.videoTitle?.trim() ?? '';
    if (url == null || url.trim().isEmpty || title.isEmpty || _playerDisposed) {
      return;
    }
    if (mounted) {
      setState(() {
        _isLoadingDanmaku = true;
        _danmakuError = null;
      });
    }
    try {
      final result = await DanmakuService.loadForVideo(
        url: url,
        title: title,
        episodeIndex: widget.currentEpisodeIndex ?? 0,
        doubanId: widget.doubanId,
        year: widget.year,
        bypassCache: bypassCache,
      );
      if (!mounted || _playerDisposed) return;
      _applyDanmakuResult(result);
    } catch (error) {
      debugPrint('VideoPlayerWidget: danmaku load failed: $error');
      if (mounted) {
        setState(() {
          _isLoadingDanmaku = false;
          _danmakuError = '弹幕服务暂不可用';
          _danmakuSource = null;
          _danmakuItems.clear();
        });
      }
    }
  }

  void _applyDanmakuResult(DanmakuResult result) {
    _danmakuItems
      ..clear()
      ..addAll(result.comments.map(_toDanmakuItem));
    setState(() {
      _isLoadingDanmaku = false;
      _danmakuSource = result.comments.isEmpty ? null : result.source;
      _danmakuError = result.comments.isEmpty
          ? (result.error?.isNotEmpty == true ? result.error : '当前视频暂无匹配弹幕')
          : null;
    });
  }

  DanmakuItem _toDanmakuItem(DanmakuComment comment) => DanmakuItem(
        id: _nextDanmakuId++,
        text: comment.text,
        position: comment.time,
        color: comment.color,
        mode: comment.mode,
      );

  void _exitWebFullscreen() {
    _exitWebFullscreenCallback?.call();
  }

  void _setupPip() {
    // iOS 的画中画只在点按钮时由原生临时创建，见 AppDelegate.swift。
    if (!Platform.isAndroid) return;
    _pip.setup(const PipOptions(
      autoEnterEnabled: false,
      aspectRatioX: 16,
      aspectRatioY: 9,
      preferredContentWidth: 480,
      preferredContentHeight: 270,
      controlStyle: 2,
    ));
  }

  void _registerPipObserver() {
    if (!Platform.isAndroid) return;
    _pip.registerStateChangedObserver(PipStateChangedObserver(
      onPipStateChanged: (state, error) {
        if (!mounted) return;
        switch (state) {
          case PipState.pipStateStarted:
            debugPrint('PiP started successfully');
            if (mounted) {
              setState(() => _isPipMode = true);
              widget.onPipModeChanged?.call(true);
            }
            break;
          case PipState.pipStateStopped:
            debugPrint('PiP stopped');
            if (mounted) {
              setState(() {
                _isPipMode = false;
              });
              widget.onPipModeChanged?.call(false);
            }
            break;
          case PipState.pipStateFailed:
            debugPrint('PiP failed: $error');
            if (mounted) {
              setState(() => _isPipMode = false);
              widget.onPipModeChanged?.call(false);
            }
            break;
        }
      },
    ));
  }

  Future<void> _enterPipMode() async {
    if (_pipTransitionInProgress || _isPipMode) return;
    _pipTransitionInProgress = true;
    debugPrint('_enterPipMode');
    try {
      if (Platform.isIOS) {
        if (_currentUrl == null || _player == null) return;
        await _player!.pause();
        final started = await _iosPipChannel.invokeMethod<bool>('start', {
              'url': _currentUrl,
              'headers': _currentHeaders ?? const <String, String>{},
              'positionMs': _player!.state.position.inMilliseconds,
            }) ??
            false;
        if (!started) await _player!.play();
        return;
      }

      var support = await _pip.isSupported();
      if (!support) {
        debugPrint('Device does not support PiP!');
        return;
      }
      await _player?.play();
      await _pip.start();
    } catch (e) {
      debugPrint('Failed to enter PiP mode: $e');
      if (Platform.isIOS) {
        await _player?.play();
      } else {
        _setupPip();
      }
    } finally {
      _pipTransitionInProgress = false;
    }
  }

  void _registerIosPipHandler() {
    if (!Platform.isIOS) return;
    _iosPipChannel.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'started':
          setState(() => _isPipMode = true);
          widget.onPipModeChanged?.call(true);
          break;
        case 'stopped':
          final arguments = call.arguments as Map<dynamic, dynamic>?;
          final positionMs = arguments?['positionMs'] as int?;
          if (positionMs != null) {
            await _player?.seek(Duration(milliseconds: positionMs));
          }
          await _player?.play();
          if (!mounted) return;
          setState(() => _isPipMode = false);
          widget.onPipModeChanged?.call(false);
          break;
        case 'failed':
          await _player?.play();
          if (!mounted) return;
          setState(() => _isPipMode = false);
          widget.onPipModeChanged?.call(false);
          debugPrint('iOS PiP failed: ${call.arguments}');
          break;
      }
    });
  }

  /// 本地下载的文件不需要再提供下载按钮。
  bool get _isLocalSource {
    final url = _currentUrl ?? '';
    if (url.isEmpty) return true;
    return !url.startsWith('http');
  }

  /// 把当前播放地址加入本地下载队列。
  Future<void> _downloadCurrent() async {
    final url = _currentUrl;
    if (url == null || url.isEmpty) return;
    final episodeIndex = widget.currentEpisodeIndex;
    final message = await DownloadService.instance.enqueue(
      title: widget.videoTitle?.trim().isNotEmpty == true
          ? widget.videoTitle!.trim()
          : '未命名视频',
      url: url,
      episodeLabel: episodeIndex == null ? '' : '第${episodeIndex + 1}集',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message ?? '已加入下载，可在「下载」分类查看进度')),
    );
  }

  Future<void> _showDanmakuPanel() async {
    var enabled = _danmakuEnabled;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('弹幕'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('显示弹幕'),
                    value: enabled,
                    onChanged: (value) {
                      setDialogState(() => enabled = value);
                      setState(() => _danmakuEnabled = value);
                      unawaited(UserDataService.saveDanmakuEnabled(value));
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _isLoadingDanmaku
                        ? '正在匹配当前视频弹幕…'
                        : _danmakuError ??
                            '已加载 ${_danmakuItems.length} 条弹幕'
                                '${_danmakuSource == null ? '' : '（${_danmakuSource!}）'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: _isLoadingDanmaku
                      ? null
                      : () {
                          Navigator.of(dialogContext).pop();
                          unawaited(_showDanmakuMatchPicker());
                        },
                  child: const Text('手动匹配'),
                ),
                TextButton(
                  onPressed: _isLoadingDanmaku
                      ? null
                      : () => unawaited(_loadDanmaku(bypassCache: true)),
                  child: const Text('重新匹配'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 自动匹配不准时，让用户从主站搜索结果里手动挑一集。
  Future<void> _showDanmakuMatchPicker() async {
    final title = widget.videoTitle?.trim() ?? '';
    if (title.isEmpty) return;

    setState(() => _isLoadingDanmaku = true);
    List<DanmakuMatch> matches;
    try {
      matches = await DanmakuService.searchMatches(title);
    } catch (error) {
      debugPrint('VideoPlayerWidget: danmaku search failed: $error');
      matches = const [];
    }
    if (!mounted) return;
    setState(() => _isLoadingDanmaku = false);

    if (matches.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('主站没有返回可匹配的弹幕剧集')),
      );
      return;
    }

    final selected = await showDialog<DanmakuMatch>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择弹幕剧集'),
        content: SizedBox(
          width: 360,
          height: 360,
          child: ListView.builder(
            itemCount: matches.length,
            itemBuilder: (context, index) => ListTile(
              dense: true,
              title: Text(matches[index].label,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.of(dialogContext).pop(matches[index]),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;

    setState(() {
      _isLoadingDanmaku = true;
      _danmakuError = null;
    });
    final result = await DanmakuService.loadByEpisodeId(
      episodeId: selected.episodeId,
      title: title,
      episodeIndex: widget.currentEpisodeIndex ?? 0,
    );
    if (!mounted || _playerDisposed) return;
    _applyDanmakuResult(result);
  }

  Future<void> _externalDispose() async {
    if (!mounted || _playerDisposed) {
      return;
    }
    await _disposePlayer();
  }

  Future<void> _disposePlayer() async {
    if (_playerDisposed) {
      return;
    }
    _playerDisposed = true;
    _positionSubscription?.cancel();
    _playingSubscription?.cancel();
    _completedSubscription?.cancel();
    _durationSubscription?.cancel();
    _progressListeners.clear();
    await _player?.dispose();
    _player = null;
    _videoController = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (_player == null) {
      return;
    }
    switch (state) {
      case AppLifecycleState.paused:
        if (Platform.isAndroid &&
            !_isPipMode &&
            (_player?.state.playing ?? false)) {
          unawaited(_enterPipMode());
        }
        break;
      case AppLifecycleState.inactive:
        // iOS 由原生的 willResignActive 直接发起画中画（此时仍在前台，系统才允许），
        // 见 ios/Runner/AppDelegate.swift，这里不再重复触发。
        break;
      case AppLifecycleState.hidden:
        break;
      case AppLifecycleState.resumed:
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid || Platform.isIOS) {
      if (Platform.isAndroid) {
        _pip.unregisterStateChangedObserver();
        _pip.dispose();
      } else {
        _iosPipChannel.setMethodCallHandler(null);
        _iosPipChannel.invokeMethod<void>('dispose');
      }
    }
    _disposePlayer();
    _playbackSpeed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: _isInitialized && _videoController != null
          ? Video(
              controller: _videoController!,
              controls: (state) {
                final controls = widget.surface == VideoPlayerSurface.desktop
                    ? PCPlayerControls(
                        state: state,
                        player: _player!,
                        onBackPressed: widget.onBackPressed,
                        onNextEpisode: widget.onNextEpisode,
                        onPause: widget.onPause,
                        videoUrl: _currentUrl ?? '',
                        isLastEpisode: widget.isLastEpisode,
                        isLoadingVideo: _isLoadingVideo,
                        onCastStarted: widget.onCastStarted,
                        videoTitle: widget.videoTitle,
                        currentEpisodeIndex: widget.currentEpisodeIndex,
                        totalEpisodes: widget.totalEpisodes,
                        sourceName: widget.sourceName,
                        onWebFullscreenChanged: widget.onWebFullscreenChanged,
                        onExitWebFullscreenCallbackReady: (callback) {
                          _exitWebFullscreenCallback = callback;
                        },
                        onExitFullScreen: widget.onExitFullScreen,
                        live: widget.live,
                        playbackSpeedListenable: _playbackSpeed,
                        onSetSpeed: _setPlaybackSpeed,
                        danmakuEnabled: _danmakuEnabled,
                        onShowDanmakuPanel: _showDanmakuPanel,
                      )
                    : MobilePlayerControls(
                        player: _player!,
                        state: state,
                        onControlsVisibilityChanged: (_) {},
                        onBackPressed: widget.onBackPressed,
                        onFullscreenChange: (_) {},
                        onNextEpisode: widget.onNextEpisode,
                        onPause: widget.onPause,
                        videoUrl: _currentUrl ?? '',
                        isLastEpisode: widget.isLastEpisode,
                        isLoadingVideo: _isLoadingVideo,
                        onCastStarted: widget.onCastStarted,
                        videoTitle: widget.videoTitle,
                        currentEpisodeIndex: widget.currentEpisodeIndex,
                        totalEpisodes: widget.totalEpisodes,
                        sourceName: widget.sourceName,
                        onExitFullScreen: widget.onExitFullScreen,
                        live: widget.live,
                        playbackSpeedListenable: _playbackSpeed,
                        onSetSpeed: _setPlaybackSpeed,
                        onEnterPipMode: _enterPipMode,
                        isPipMode: _isPipMode,
                        danmakuEnabled: _danmakuEnabled,
                        onShowDanmakuPanel: _showDanmakuPanel,
                        onDownload: _isLocalSource ? null : _downloadCurrent,
                      );
                return Stack(
                  children: [
                    DanmakuOverlay(
                      player: _player!,
                      items: _danmakuItems,
                      enabled: _danmakuEnabled,
                    ),
                    controls,
                  ],
                );
              },
            )
          : const Center(
              child: CircularProgressIndicator(
                color: Colors.white,
              ),
            ),
    );
  }
}
