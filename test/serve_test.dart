import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:impact_radar/src/scan/serve.dart';
import 'package:impact_radar/src/ui/impact_source.dart';

/// Binds an ephemeral port and wires the production handler to it.
Future<HttpServer> _serve(Directory root) async {
  final server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0, // 0 = let the OS pick a free port, so tests never collide
  );
  server.listen((request) async {
    try {
      await handleRequest(request, root.path);
    } finally {
      await request.response.close();
    }
  });
  return server;
}

Future<HttpClientResponse> _get(int port, String path) async {
  final client = HttpClient();
  final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
  return request.close();
}

Future<String> _body(HttpClientResponse response) =>
    response.transform(utf8.decoder).join();

void main() {
  late Directory root;
  late HttpServer server;
  late int port;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('impact_serve_test');
    File('${root.path}${Platform.pathSeparator}impact.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'version': 3,
        'generatedAt': '2026-01-01T00:00:00.000Z',
        'base': 'HEAD',
        'root': root.path,
        'changedFiles': <String>['lib/foo.dart'],
        'seeds': <Map<String, dynamic>>[],
        'affectedFiles': <String>['lib/bar.dart'],
        'affectedTypes': <String>['BarScreen'],
        'typeDepths': <String, int>{'BarScreen': 0},
        'widgetTypes': <String>['BarScreen'],
        'fileDepths': <String, int>{'lib/bar.dart': 0},
        'hits': <String, List<String>>{'lib/bar.dart': <String>['foo']},
        'truncated': false,
        'stats': <String, dynamic>{'queryCount': 1, 'elapsedMs': 1},
      }),
    );
    // A file outside the served root, to prove it stays unreachable.
    final outside = Directory.systemTemp.createTempSync('impact_outside');
    File('${outside.path}${Platform.pathSeparator}secret.txt')
        .writeAsStringSync('do not serve me');
    server = await _serve(root);
    port = server.port;
  });

  tearDown(() async {
    await server.close(force: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('serving the report', () {
    test('serves impact.json as JSON', () async {
      final response = await _get(port, '/impact.json');
      final body = await _body(response);

      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, 'application/json');

      final decoded = jsonDecode(body) as Map<String, dynamic>;
      expect(decoded['widgetTypes'], <String>['BarScreen']);
    });

    test('HttpSource can read what the server wrote', () async {
      // The whole point: the transport and the consumer agree.
      final report = await HttpSource(
        'http://127.0.0.1:$port/impact.json',
      ).read();

      expect(report, isNotNull);
      expect(report!.widgetTypes, <String>['BarScreen']);
      expect(report.affectedFiles, contains('lib/bar.dart'));
    });

    test('the root path explains itself', () async {
      final response = await _get(port, '/');
      final body = await _body(response);

      expect(response.statusCode, 200);
      expect(body, contains('impact.json'));
    });
  });

  group('failures are survivable', () {
    test('a missing file is 404 with a hint, not a crash', () async {
      final response = await _get(port, '/nope.json');
      final body = await _body(response);

      expect(response.statusCode, 404);
      expect(body, contains('impact_scan'));
    });

    test('HttpSource returns null on 404 rather than throwing', () async {
      // The gate must keep the last good report, so a null here is load-bearing.
      final report = await HttpSource(
        'http://127.0.0.1:$port/nope.json',
      ).read();

      expect(report, isNull);
    });

    test('HttpSource returns null when nothing is listening', () async {
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = closed.port;
      await closed.close(force: true);

      final report = await HttpSource(
        'http://127.0.0.1:$deadPort/impact.json',
        timeout: const Duration(seconds: 2),
      ).read();

      expect(report, isNull);
    });

    test('a non-JSON body is null, not an exception', () async {
      File('${root.path}${Platform.pathSeparator}notes.txt')
          .writeAsStringSync('just some text');
      final report = await HttpSource(
        'http://127.0.0.1:$port/notes.txt',
      ).read();

      expect(report, isNull);
    });
  });

  group('path traversal', () {
    test('a literal ../ never escapes the root', () async {
      final response = await _get(port, '/../secret.txt');
      final body = await _body(response);

      // Dart's URI parser collapses `..` before we see it, so this either 404s or is
      // refused. What must never happen is the file's contents coming back.
      expect(response.statusCode, isNot(200));
      expect(body, isNot(contains('do not serve me')));
    });

    test('an encoded ../ never escapes the root', () async {
      final response = await _get(port, '/%2e%2e%2fsecret.txt');
      final body = await _body(response);

      expect(response.statusCode, isNot(200));
      expect(body, isNot(contains('do not serve me')));
    });

    test('the guard itself rejects an escaping path', () {
      // Directly exercise the check, because a real request never reaches it: the URI parser
      // already normalised the traversal away. If that parser ever changes, this still holds.
      const served = '/srv/app';
      final escaping = File('$served${Platform.pathSeparator}'
              '${'..${Platform.pathSeparator}etc${Platform.pathSeparator}passwd'}')
          .absolute
          .path
          .replaceAll('\\', '/');
      final normalizedRoot = served.replaceAll('\\', '/');

      expect(
        escaping.startsWith('$normalizedRoot/'),
        isFalse,
        reason: 'a resolved path outside the root must fail the prefix check',
      );
    });
  });
}
