/// A minimal Language Server Protocol client over stdio.
///
/// This is deliberately small: it speaks just enough LSP to drive Dart's analysis server
/// for `textDocument/references` and `textDocument/documentSymbol`. The analysis server
/// already maintains a reference index (that is how an IDE answers "find references"
/// instantly), so we borrow it instead of building our own dependency graph.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef LogFn = void Function(String message);

class LspException implements Exception {
  LspException(this.message);
  final String message;
  @override
  String toString() => 'LspException: $message';
}

/// A resolved symbol location, in plain values.
class LspLocation {
  const LspLocation(this.path, this.line, this.character, this.endLine);

  /// Absolute file path.
  final String path;

  /// 0-based, as LSP uses.
  final int line;
  final int character;
  final int endLine;

  @override
  String toString() => '$path:${line + 1}';
}

class LspClient {
  LspClient({LogFn? log}) : _log = log ?? ((_) {});

  final LogFn _log;

  Process? _process;
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  Completer<int>? _exit;

  final List<int> _inbox = <int>[];
  final Map<int, Completer<dynamic>> _pending = <int, Completer<dynamic>>{};
  int _nextId = 1;
  bool _disposed = false;

  static const List<int> _headerEnd = <int>[13, 10, 13, 10]; // \r\n\r\n

  /// Spawns the server. Throws [LspException] if it dies immediately, which is how the
  /// caller detects an unsupported server command and can try the next candidate.
  Future<void> start({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
  }) async {
    _log('spawn: $executable ${arguments.join(' ')}  (cwd: $workingDirectory)');
    _process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    _exit = Completer<int>();

    unawaited(
      _process!.exitCode.then((code) {
        if (!(_exit?.isCompleted ?? true)) _exit!.complete(code);
        _failPending('analysis server exited with code $code');
      }),
    );

    _stdoutSub = _process!.stdout.listen(
      _onStdout,
      onDone: () {
        if (!(_exit?.isCompleted ?? true)) _exit!.complete(-1);
        _failPending('analysis server closed its output stream');
      },
      onError: (Object e) => _failPending('analysis server stdout error: $e'),
    );
    _stderrSub = _process!.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isNotEmpty) _log('[server] $line');
    });

    // If the process is going to reject us, find out now rather than on first request.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (_exit?.isCompleted ?? false) {
      throw LspException(
        'server exited immediately (code ${_exit!.future})',
      );
    }
  }

  Future<void> initialize({required String rootPath}) async {
    final rootUri = fileUriOf(rootPath);
    await request('initialize', <String, dynamic>{
      'processId': pid,
      'clientInfo': <String, dynamic>{
        'name': 'impact_radar',
        'version': '0.1.0',
      },
      'rootUri': rootUri,
      'capabilities': <String, dynamic>{
        'textDocument': <String, dynamic>{
          'documentSymbol': <String, dynamic>{
            'hierarchicalDocumentSymbolSupport': true,
          },
          'references': <String, dynamic>{},
        },
        'workspace': <String, dynamic>{
          'workspaceFolders': true,
          'configuration': false,
        },
      },
      'workspaceFolders': <Map<String, dynamic>>[
        <String, dynamic>{'uri': rootUri, 'name': _basename(rootPath)},
      ],
    });
    notify('initialized', <String, dynamic>{});
    _log('initialized for $rootPath');
  }

  /// Who references the symbol at [line]/[character]?
  ///
  /// A position with no symbol at or after it is normal, not an error — an empty result is
  /// returned. Only genuine protocol failures throw.
  Future<List<LspLocation>> references({
    required String path,
    required int line,
    required int character,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    dynamic result;
    try {
      result = await request(
        'textDocument/references',
        <String, dynamic>{
          'textDocument': <String, dynamic>{'uri': fileUriOf(path)},
          'position': <String, dynamic>{'line': line, 'character': character},
          'context': <String, dynamic>{'includeDeclaration': false},
        },
        timeout: timeout,
      );
    } on LspException catch (e) {
      // "No references found" and similar come back as errors, not empty arrays.
      _log('references error at ${_basename(path)}:${line + 1} -> $e');
      return const <LspLocation>[];
    }
    return _parseLocations(result);
  }

  /// The symbol tree of a file, as returned by `textDocument/documentSymbol`.
  Future<List<Map<String, dynamic>>> documentSymbols({
    required String path,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final result = await request(
      'textDocument/documentSymbol',
      <String, dynamic>{
        'textDocument': <String, dynamic>{'uri': fileUriOf(path)},
      },
      timeout: timeout,
    );
    if (result is! List) return const <Map<String, dynamic>>[];
    return result.whereType<Map<String, dynamic>>().toList();
  }

  Future<dynamic> request(
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) {
    final proc = _process;
    if (proc == null || _disposed) {
      return Future<dynamic>.error(LspException('client is not running'));
    }
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    if (timeout == null) return completer.future;
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw LspException('$method timed out after ${timeout.inSeconds}s');
      },
    );
  }

  void notify(String method, Map<String, dynamic> params) {
    _send(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      notify('shutdown', <String, dynamic>{});
      notify('exit', <String, dynamic>{});
    } catch (_) {
      // Server may already be gone; nothing useful to do.
    }
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _process?.kill();
    _failPending('client disposed');
  }

  // --- transport -------------------------------------------------------------------

  void _onStdout(List<int> data) {
    _inbox.addAll(data);
    while (true) {
      final headerEnd = _indexOf(_inbox, _headerEnd);
      if (headerEnd < 0) return;
      final header = utf8.decode(
        _inbox.sublist(0, headerEnd),
        allowMalformed: true,
      );
      final match = RegExp(
        r'content-length:\s*(\d+)',
        caseSensitive: false,
      ).firstMatch(header);
      if (match == null) {
        // Unparseable header: drop it and resync.
        _inbox.removeRange(0, headerEnd + _headerEnd.length);
        continue;
      }
      final length = int.parse(match.group(1)!);
      final bodyStart = headerEnd + _headerEnd.length;
      if (_inbox.length < bodyStart + length) return; // wait for more bytes
      final body = utf8.decode(
        _inbox.sublist(bodyStart, bodyStart + length),
        allowMalformed: true,
      );
      _inbox.removeRange(0, bodyStart + length);
      _dispatch(body);
    }
  }

  void _dispatch(String body) {
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final map = decoded.cast<String, dynamic>();

    // Server -> client request (has both id and method). Must be answered or the server
    // may block waiting on us.
    if (map.containsKey('id') && map.containsKey('method')) {
      _answerServerRequest(map);
      return;
    }

    final id = map['id'];
    if (id is int) {
      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;
      final error = map['error'];
      if (error != null) {
        completer.completeError(
          LspException(error is Map ? '${error['message']}' : '$error'),
        );
      } else {
        completer.complete(map['result']);
      }
      return;
    }
    // Plain notification from the server; nothing we need from it in v1.
  }

  void _answerServerRequest(Map<String, dynamic> msg) {
    final id = msg['id'];
    final method = msg['method'];
    dynamic result;
    switch (method) {
      case 'workspace/configuration':
        final items = (msg['params']?['items'] as List?) ?? const <dynamic>[];
        result = List<dynamic>.filled(items.length, null);
      case 'client/registerCapability':
      case 'client/unregisterCapability':
      case 'window/workDoneProgress/create':
      case 'dart/showDocumentation':
        result = null;
      default:
        _log('unanswered server request: $method');
        result = null;
    }
    _send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    });
  }

  void _send(Map<String, dynamic> message) {
    final proc = _process;
    if (proc == null || _disposed) return;
    final body = utf8.encode(jsonEncode(message));
    proc.stdin.add(<int>[
      ...utf8.encode('Content-Length: ${body.length}\r\n\r\n'),
      ...body,
    ]);
  }

  void _failPending(String reason) {
    if (_pending.isEmpty) return;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(LspException(reason));
    }
    _pending.clear();
  }

  // --- helpers ---------------------------------------------------------------------

  List<LspLocation> _parseLocations(dynamic result) {
    if (result is! List) return const <LspLocation>[];
    final out = <LspLocation>[];
    for (final item in result) {
      if (item is! Map) continue;
      final uri = item['uri'];
      final range = item['range'];
      if (uri is! String || range is! Map) continue;
      final start = range['start'];
      if (start is! Map) continue;
      final line = start['line'];
      final character = start['character'];
      if (line is! int || character is! int) continue;
      final end = range['end'];
      out.add(
        LspLocation(
          pathOfUri(uri),
          line,
          character,
          end is Map && end['line'] is int ? end['line'] as int : line,
        ),
      );
    }
    return out;
  }
}

/// `C:\a\b` -> `file:///C:/a/b`
String fileUriOf(String absolutePath) => Uri.file(absolutePath).toString();

/// `file:///C:/a/b` -> `C:\a\b`
String pathOfUri(String uri) => Uri.parse(uri).toFilePath();

String _basename(String p) {
  final i = p.replaceAll('\\', '/').lastIndexOf('/');
  return i < 0 ? p : p.substring(i + 1);
}

int _indexOf(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return -1;
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
