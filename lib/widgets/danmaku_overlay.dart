import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

class DanmakuItem {
  const DanmakuItem({
    required this.id,
    required this.text,
    required this.position,
  });

  final int id;
  final String text;
  final Duration position;
}

class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.player,
    required this.items,
    required this.enabled,
  });

  final Player player;
  final List<DanmakuItem> items;
  final bool enabled;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay> {
  static const _visibleDuration = Duration(seconds: 8);
  StreamSubscription<Duration>? _positionSubscription;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _listenToPosition();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _listenToPosition();
    }
  }

  void _listenToPosition() {
    _positionSubscription?.cancel();
    _position = widget.player.state.position;
    _positionSubscription = widget.player.stream.position.listen((position) {
      if (mounted) {
        setState(() => _position = position);
      }
    });
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.items.isEmpty) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final laneCount = (constraints.maxHeight * 0.55 / 30)
                .floor()
                .clamp(1, 8)
                .toInt();
            final activeItems = widget.items.where((item) {
              final elapsed = _position - item.position;
              return !elapsed.isNegative && elapsed <= _visibleDuration;
            });

            return ClipRect(
              child: Stack(
                children: activeItems.map((item) {
                  final elapsed = _position - item.position;
                  final progress =
                      (elapsed.inMilliseconds / _visibleDuration.inMilliseconds)
                          .clamp(0.0, 1.0)
                          .toDouble();
                  final textWidth = (item.text.runes.length * 18.0)
                      .clamp(80.0, 420.0)
                      .toDouble();
                  final left =
                      constraints.maxWidth -
                      progress * (constraints.maxWidth + textWidth);
                  final lane = item.id % laneCount;

                  return Positioned(
                    left: left,
                    top: 12 + lane * 30.0,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Text(
                        item.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          shadows: [
                            Shadow(
                              color: Colors.black,
                              blurRadius: 3,
                              offset: Offset(1, 1),
                            ),
                            Shadow(
                              color: Colors.black,
                              blurRadius: 3,
                              offset: Offset(-1, -1),
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
        ),
      ),
    );
  }
}
