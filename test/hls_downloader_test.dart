import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:selene/services/hls_downloader.dart';

/// 起一个本地 HTTP 服务返回 m3u8 与分片，验证下载、解密、合并的整条链路。
Future<HttpServer> _serve({
  required String playlist,
  required Map<String, List<int>> files,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final name = request.uri.pathSegments.last;
    if (name == 'index.m3u8') {
      request.response.headers.contentType =
          ContentType('application', 'vnd.apple.mpegurl');
      request.response.write(playlist);
    } else if (files.containsKey(name)) {
      request.response.add(files[name]!);
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  });
  return server;
}

Uint8List _encryptAes128Cbc(List<int> data, Uint8List key, Uint8List iv) {
  // PKCS7 填充后整块加密，模拟真实加密源的输出。
  final padding = 16 - (data.length % 16);
  final padded = Uint8List(data.length + padding)
    ..setRange(0, data.length, data)
    ..fillRange(data.length, data.length + padding, padding);

  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(key), iv));
  final output = Uint8List(padded.length);
  for (var i = 0; i < padded.length ~/ 16; i++) {
    cipher.processBlock(padded, i * 16, output, i * 16);
  }
  return output;
}

void main() {
  test('识别播放列表地址', () {
    expect(HlsDownloader.isPlaylist('https://a.com/b/index.m3u8'), isTrue);
    expect(HlsDownloader.isPlaylist('https://a.com/b/v.mp4'), isFalse);
  });

  test('下载格式对应正确的后缀', () {
    expect(DownloadFormat.ts.extension, '.ts');
    expect(DownloadFormat.mp4.extension, '.mp4');
  });

  test('合并明文分片', () async {
    final server = await _serve(
      playlist: '#EXTM3U\n'
          '#EXTINF:1,\n0.ts\n'
          '#EXTINF:1,\n1.ts\n'
          '#EXT-X-ENDLIST\n',
      files: {
        '0.ts': [1, 2, 3],
        '1.ts': [4, 5, 6],
      },
    );
    addTearDown(() => server.close(force: true));

    final dir = await Directory.systemTemp.createTemp('hls-plain');
    addTearDown(() => dir.delete(recursive: true));
    final target = File('${dir.path}/out.ts');

    await HlsDownloader(dio: Dio()).download(
      url: 'http://${server.address.address}:${server.port}/index.m3u8',
      target: target,
      cancelToken: CancelToken(),
    );

    expect(await target.readAsBytes(), [1, 2, 3, 4, 5, 6]);
  });

  test('解密 AES-128 分片并按序合并', () async {
    final key = Uint8List.fromList(List<int>.generate(16, (i) => i));
    final iv = Uint8List.fromList(List<int>.generate(16, (i) => 16 - i));
    final first = List<int>.generate(40, (i) => i);
    final second = List<int>.generate(24, (i) => 100 + i);

    final ivHex =
        iv.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

    final server = await _serve(
      playlist: '#EXTM3U\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x$ivHex\n'
          '#EXTINF:1,\n0.ts\n'
          '#EXTINF:1,\n1.ts\n'
          '#EXT-X-ENDLIST\n',
      files: {
        'key.bin': key,
        '0.ts': _encryptAes128Cbc(first, key, iv),
        '1.ts': _encryptAes128Cbc(second, key, iv),
      },
    );
    addTearDown(() => server.close(force: true));

    final dir = await Directory.systemTemp.createTemp('hls-aes');
    addTearDown(() => dir.delete(recursive: true));
    final target = File('${dir.path}/out.mp4');

    await HlsDownloader(dio: Dio()).download(
      url: 'http://${server.address.address}:${server.port}/index.m3u8',
      target: target,
      cancelToken: CancelToken(),
    );

    expect(await target.readAsBytes(), [...first, ...second]);
  });
}
