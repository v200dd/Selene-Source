import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';

/// 下载格式。
///
/// - [ts]：把所有分片按顺序拼成一个 `.ts`，最省事、兼容性最好。
/// - [mp4]：同样合并分片，但输出 `.mp4` 后缀。容器仍是 MPEG-TS 字节流，
///   mpv/VLC 及本 App 播放器都能放；这里不做真正的重封装，因为那需要
///   随包携带 ffmpeg，体积代价太大。
enum DownloadFormat { ts, mp4 }

extension DownloadFormatLabel on DownloadFormat {
  String get label => this == DownloadFormat.ts ? 'TS' : 'MP4';
  String get extension => this == DownloadFormat.ts ? '.ts' : '.mp4';
}

/// 一条 m3u8 分片。
class _Segment {
  _Segment({
    required this.index,
    required this.url,
    this.key,
    this.iv,
  });

  final int index;
  final String url;
  final Uint8List? key;
  final Uint8List? iv;
}

/// M3U8 客户端下载：拉取播放列表、并发下载 TS 分片、解密 AES-128、按序合并。
///
/// 全程在设备本地完成，不占用服务器存储和带宽。
class HlsDownloader {
  HlsDownloader({
    required this.dio,
    this.concurrency = 6,
    this.maxRetries = 3,
  });

  final Dio dio;

  /// 并发下载的分片数。
  final int concurrency;

  /// 单个分片的重试次数。
  final int maxRetries;

  static bool isPlaylist(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }

  /// 下载并合并到 [target]。
  ///
  /// [onProgress] 回调 `(已完成分片, 总分片, 已写入字节)`。
  Future<void> download({
    required String url,
    required File target,
    required CancelToken cancelToken,
    void Function(int done, int total, int bytes)? onProgress,
  }) async {
    final segments = await _resolveSegments(url, cancelToken);
    if (segments.isEmpty) {
      throw Exception('播放列表里没有可下载的分片');
    }

    // 分片先落到临时目录，全部成功后再按序合并，避免半成品覆盖旧文件。
    final workDir = Directory(
        '${target.parent.path}/.${target.uri.pathSegments.last}.parts');
    if (!await workDir.exists()) await workDir.create(recursive: true);

    var done = 0;
    var bytes = 0;
    var next = 0;

    Future<void> worker() async {
      while (true) {
        if (cancelToken.isCancelled) return;
        final current = next++;
        if (current >= segments.length) return;
        final segment = segments[current];
        final part = File('${workDir.path}/${segment.index}.part');
        if (!await part.exists()) {
          final data = await _fetchSegment(segment, cancelToken);
          await part.writeAsBytes(data, flush: false);
          bytes += data.length;
        } else {
          bytes += await part.length();
        }
        done++;
        onProgress?.call(done, segments.length, bytes);
      }
    }

    try {
      await Future.wait(
        List.generate(
          concurrency < segments.length ? concurrency : segments.length,
          (_) => worker(),
        ),
      );

      if (cancelToken.isCancelled) return;

      final sink = target.openWrite();
      try {
        for (final segment in segments) {
          final part = File('${workDir.path}/${segment.index}.part');
          if (!await part.exists()) {
            throw Exception('分片 ${segment.index} 缺失，请重试');
          }
          await sink.addStream(part.openRead());
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } finally {
      if (await workDir.exists() && !cancelToken.isCancelled) {
        await workDir.delete(recursive: true);
      }
    }
  }

  /// 解析播放列表，跟随一层 master playlist，收集分片与加密信息。
  Future<List<_Segment>> _resolveSegments(
    String url,
    CancelToken cancelToken, {
    int depth = 0,
  }) async {
    if (depth > 2) throw Exception('播放列表嵌套过深');

    final body = await _fetchText(url, cancelToken);
    final lines = body
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    // master playlist：挑第一个码流继续解析。
    if (lines.any((line) => line.startsWith('#EXT-X-STREAM-INF'))) {
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
        for (var j = i + 1; j < lines.length; j++) {
          if (lines[j].startsWith('#')) continue;
          return _resolveSegments(
            _absolute(url, lines[j]),
            cancelToken,
            depth: depth + 1,
          );
        }
      }
    }

    final segments = <_Segment>[];
    Uint8List? key;
    Uint8List? iv;
    var index = 0;

    for (final line in lines) {
      if (line.startsWith('#EXT-X-KEY')) {
        final method = _attribute(line, 'METHOD') ?? 'NONE';
        if (method.toUpperCase() == 'NONE') {
          key = null;
          iv = null;
          continue;
        }
        if (!method.toUpperCase().startsWith('AES-128')) {
          throw Exception('暂不支持的加密方式：$method');
        }
        final keyUri = _attribute(line, 'URI');
        if (keyUri == null) throw Exception('加密视频缺少密钥地址');
        key = await _fetchBytes(_absolute(url, keyUri), cancelToken);
        final ivText = _attribute(line, 'IV');
        iv = ivText == null ? null : _parseHex(ivText);
        continue;
      }
      if (line.startsWith('#')) continue;

      segments.add(_Segment(
        index: index,
        url: _absolute(url, line),
        key: key,
        // 没给 IV 时按规范用分片序号补齐 16 字节。
        iv: key == null ? null : (iv ?? _ivFromSequence(index)),
      ));
      index++;
    }
    return segments;
  }

  Future<Uint8List> _fetchSegment(
    _Segment segment,
    CancelToken cancelToken,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      if (cancelToken.isCancelled) return Uint8List(0);
      try {
        final data = await _fetchBytes(segment.url, cancelToken);
        final key = segment.key;
        if (key == null) return data;
        return _decryptAes128Cbc(data, key, segment.iv!);
      } catch (error) {
        if (error is DioException && CancelToken.isCancel(error)) rethrow;
        lastError = error;
        // 退避重试，服务端限流时给它一点喘息时间。
        await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
    throw Exception('分片下载失败：$lastError');
  }

  Future<String> _fetchText(String url, CancelToken cancelToken) async {
    final response = await dio.get<String>(
      url,
      cancelToken: cancelToken,
      options: Options(responseType: ResponseType.plain),
    );
    final body = response.data;
    if (body == null || body.isEmpty) throw Exception('播放列表为空');
    return body;
  }

  Future<Uint8List> _fetchBytes(String url, CancelToken cancelToken) async {
    final response = await dio.get<List<int>>(
      url,
      cancelToken: cancelToken,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(response.data ?? const []);
  }

  static Uint8List _decryptAes128Cbc(
    Uint8List data,
    Uint8List key,
    Uint8List iv,
  ) {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));

    // AES 是 16 字节分组；尾部不足一组的数据原样保留，避免损坏最后一帧。
    final blockCount = data.length ~/ 16;
    final output = Uint8List(data.length);
    for (var i = 0; i < blockCount; i++) {
      cipher.processBlock(data, i * 16, output, i * 16);
    }
    final tail = data.length % 16;
    if (tail != 0) {
      output.setRange(blockCount * 16, data.length,
          data.sublist(blockCount * 16, data.length));
    }

    // 去掉 PKCS7 填充（只有整块数据才有填充）。
    if (tail == 0 && output.isNotEmpty) {
      final pad = output.last;
      if (pad >= 1 && pad <= 16 && pad <= output.length) {
        return Uint8List.sublistView(output, 0, output.length - pad);
      }
    }
    return output;
  }

  static Uint8List _ivFromSequence(int sequence) {
    final iv = Uint8List(16);
    var value = sequence;
    for (var i = 15; i >= 12 && value > 0; i--) {
      iv[i] = value & 0xff;
      value >>= 8;
    }
    return iv;
  }

  static Uint8List _parseHex(String text) {
    var clean = text.trim();
    if (clean.toLowerCase().startsWith('0x')) clean = clean.substring(2);
    if (clean.length.isOdd) clean = '0$clean';
    final bytes = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  static String? _attribute(String line, String name) {
    final match = RegExp('$name=("([^"]*)"|([^,]*))').firstMatch(line);
    if (match == null) return null;
    return (match.group(2) ?? match.group(3))?.trim();
  }

  static String _absolute(String base, String reference) {
    if (reference.startsWith('http://') || reference.startsWith('https://')) {
      return reference;
    }
    return Uri.parse(base).resolve(reference).toString();
  }
}
