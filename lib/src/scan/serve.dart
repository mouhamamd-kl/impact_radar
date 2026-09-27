/// Serves a scanned project directory over HTTP so a device can read the report.
///
/// The scanner writes `impact.json` on your machine. An app running on a phone cannot see
/// that file: a relative path resolves inside the app's own sandbox. This closes the gap by
/// putting the file somewhere the app can actually reach.
///
/// The server is deliberately dumb — it serves files and nothing else. It does not scan, and
/// it has no idea what a report is. Point a tunnel at it and point the app at the tunnel:
///
/// ```bash
/// impact serve --project path/to/app
/// ngrok http 8787
/// flutter run --dart-define=IMPACT_URL=https://<subdomain>.ngrok-free.app/impact.json
/// ```
///
/// Or, without a public URL:
///
/// ```bash
/// impact serve --project path/to/app
/// adb reverse tcp:8787 tcp:8787
/// flutter run    # IMPACT_URL already defaults to http://127.0.0.1:8787/impact.json
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Starts a static file server for [root] on [port].
///
/// Binds to all interfaces so a phone on the same network can reach it, and so a tunnel
/// process on the same machine can forward to it.
Future<HttpServer> serveProject({
  required String root,
  int port = 8787,
  void Function(String message)? log,
}) async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  // stdout.writeln takes an optional Object?, so it is not a `void Function(String)`.
  final write = log ?? (String m) => stdout.writeln(m);
  write('');
  write('  serving  ${root.replaceAll('\\', '/')}');
  write('  local    http://127.0.0.1:$port/impact.json');
  write('');
  write('  Tunnel it for a device:');
  write('    ngrok http $port                          (public HTTPS)');
  write('    adb reverse tcp:$port tcp:$port            (private, USB only)');
  write('');

  unawaited(
    server.forEach((request) async {
      await handleRequest(request, root, log: write);
      await request.response.close();
    }),
  );
  return server;
}

/// Answers one request. Public so it can be tested against a bound server directly.
Future<void> handleRequest(
  HttpRequest request,
  String root, {
  void Function(String message)? log,
}) async {
  final write = log ?? ((_) {});
  final response = request.response;
  // A tunnel forwards from the browser or the device, so allow any origin. This serves dev
  // data over a local tunnel; it is not meant to be exposed deliberately.
  response.headers.set('Access-Control-Allow-Origin', '*');
  // Never cache: a stale impact.json is exactly the confusion this tool cannot afford.
  response.headers.set(HttpHeaders.cacheControlHeader, 'no-store, no-cache');

  // `request.uri.path` is already percent-decoded by Dart's URI parser, which also collapses
  // `.` and `..` segments. Decoding it again here would be a double decode, and would let an
  // encoded traversal reach the check below in its raw form.
  final requested = request.uri.path;
  if (requested == '/' || requested.isEmpty) {
    _json(response, 200, <String, dynamic>{
      'service': 'impact_radar',
      'endpoints': <String>['/impact.json'],
    });
    return;
  }

  // Resolve inside the root and reject anything that escapes it. A tunnel makes this
  // reachable by strangers, so `../../` has to be a hard 403, not a best effort.
  final relative = requested.startsWith('/') ? requested.substring(1) : requested;
  final resolved = File('$root${Platform.pathSeparator}'
      '${relative.replaceAll('/', Platform.pathSeparator)}').absolute.path;
  final normalizedRoot = root.replaceAll('\\', '/');
  final normalizedResolved = resolved.replaceAll('\\', '/');
  if (!normalizedResolved.startsWith('$normalizedRoot/')) {
    _json(response, 403, <String, dynamic>{'error': 'outside the served directory'});
    write('  403  $requested');
    return;
  }

  final file = File(resolved);
  if (!file.existsSync()) {
    _json(response, 404, <String, dynamic>{
      'error': 'not found',
      'hint': 'run impact_scan first',
    });
    write('  404  $requested');
    return;
  }

  response.statusCode = 200;
  response.headers.contentType = ContentType(
    'application',
    'json',
    charset: 'utf-8',
  );
  response.write(file.readAsStringSync());
  write('  200  $requested');
}

void _json(HttpResponse response, int status, Map<String, dynamic> body) {
  response.statusCode = status;
  response.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
  response.write(const JsonEncoder.withIndent('  ').convert(body));
}
