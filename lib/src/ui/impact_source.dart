/// Where the runtime gets its report from.
///
/// The scanner writes `impact.json` on the machine you ran it on. The app is usually running
/// somewhere else — a phone, a tablet — and a relative path like `impact.json` resolves
/// against the *app's* working directory, not yours. So on a device the file simply is not
/// there, and the gate has nothing to show.
///
/// This is the one abstraction that fixes that. Everything else in the package is transport
/// agnostic, and the widget tests keep using [FileSource] because it needs no network.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../model/impact_report.dart';

/// A place a report can be read from.
abstract class ImpactSource {
  /// The current report, or null if there isn't one yet.
  ///
  /// Must not throw: a source that is briefly unavailable has to be survivable, because the
  /// app should keep showing the last good report rather than blanking the screen.
  Future<ImpactReport?> read();
}

/// Reads a report from a file on this machine.
///
/// Right for desktop, and for tests. On a device the path resolves inside the app's own
/// sandbox, so this finds nothing unless the report was bundled as an asset.
class FileSource implements ImpactSource {
  const FileSource(this.path);

  final String path;

  @override
  Future<ImpactReport?> read() async => readReportFile(path);
}

/// Polls a URL for a report.
///
/// Works from a phone, a tablet, or anywhere the URL is reachable. Pair it with
/// `impact serve` plus a tunnel (ngrok for HTTPS, `adb reverse` for a private local one) and
/// the app picks up a new scan within a poll interval.
class HttpSource implements ImpactSource {
  HttpSource(
    this.url, {
    this.timeout = const Duration(seconds: 5),
    HttpClient? client,
  }) : _client = client ?? HttpClient();

  /// Where to fetch. Point this at whatever the tunnel printed.
  final String url;

  final Duration timeout;
  final HttpClient _client;

  @override
  Future<ImpactReport?> read() async {
    try {
      final request = await _client.getUrl(Uri.parse(url)).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      final body = await utf8.decoder.bind(response).join().timeout(timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      return ImpactReport.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      // Server down, DNS failure, wrong URL, a truncated body. All of these mean "no new
      // report", not "crash the app" — the gate keeps what it already has.
      return null;
    }
  }

  void close() => _client.close();
}

/// Picks a source from a URL, or a file path.
///
/// The `--dart-define=IMPACT_URL=...` escape hatch, so switching between a local tunnel and
/// a public one needs no code edit.
ImpactSource impactSourceFromEnv({
  String filePath = 'impact.json',
  String url = _defaultUrl,
}) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return FileSource(filePath);
  return HttpSource(trimmed);
}

/// Overridable at build time: `flutter run --dart-define=IMPACT_URL=https://...`.
///
/// The default is the local tunnel, which is the private option and the one to use when the
/// device is connected over USB.
const _defaultUrl = String.fromEnvironment(
  'IMPACT_URL',
  defaultValue: 'http://127.0.0.1:8787/impact.json',
);
