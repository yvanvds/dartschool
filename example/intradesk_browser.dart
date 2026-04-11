library;

///
/// Run with:
///   dart run example/intradesk_browser.dart
///
/// Controls:
///   U / D          Move selection up / down
///   Enter          Enter a folder  –or–  download a file
///   B / Backspace  Go back to the parent folder
///   Q              Quit
///
/// Downloaded files are saved to the current working directory.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_smartschool/flutter_smartschool.dart';

// ─── ANSI helpers ────────────────────────────────────────────────────────────

const _esc = '\x1B';
const _csi = '$_esc[';

String _fg(int n) =>
    '$_csi${n}m'; // ignore: unnecessary_brace_in_string_interps
String _bg(int n) =>
    '$_csi${n}m'; // ignore: unnecessary_brace_in_string_interps
const _bold = '${_csi}1m';
const _dim = '${_csi}2m';
const _reset = '${_csi}0m';
const _clearScreen = '${_csi}2J${_csi}H';
const _hideCursor = '$_csi?25l';
const _showCursor = '$_csi?25h';
const _clearEol = '${_csi}0K';

void _write(String s) => stdout.write(s);
void _writeln([String s = '']) => stdout.writeln(s);

// ─── Key constants ──────────────────────────────────────────────────────────

const _kUp1 = [0x75]; // u
const _kUp2 = [0x55]; // U
const _kDown1 = [0x64]; // d
const _kDown2 = [0x44]; // D
const _kBack1 = [0x62]; // b
const _kBack2 = [0x42]; // B
const _kBackspace1 = [0x7F]; // DEL
const _kBackspace2 = [0x08]; // BS
const _kEnter1 = [0x0D]; // CR
const _kEnter2 = [0x0A]; // LF
const _kQ1 = [0x71]; // q
const _kQ2 = [0x51]; // Q

// ─── Navigation state ────────────────────────────────────────────────────────

/// One entry in the breadcrumb / back-stack.
class _Level {
  final String name;

  /// `null` = root.
  final String? folderId;

  /// The index that was selected when we navigated *into* this level, so that
  /// going back restores the same position.
  final int selectedIndex;

  const _Level({
    required this.name,
    required this.folderId,
    required this.selectedIndex,
  });
}

/// A single row displayed in the listing – either a folder or a file.
class _Row {
  final bool isFolder;
  final String name;
  final String id;
  final int? fileSize; // bytes, files only

  const _Row({
    required this.isFolder,
    required this.name,
    required this.id,
    this.fileSize,
  });
}

// ─── UI rendering ────────────────────────────────────────────────────────────

void _renderScreen({
  required List<_Level> stack,
  required List<_Row> rows,
  required int selected,
  required int terminalWidth,
  String? statusMessage,
}) {
  _write(_clearScreen);

  // Header
  final headerBar = '─' * terminalWidth;
  _writeln('$_bold${_fg(96)} Smartschool Intradesk Browser$_reset');
  _writeln(_dim + headerBar + _reset);

  // Breadcrumb
  final crumb = stack.map((l) => l.name).join('  ›  ');
  _writeln('  $_dim$crumb$_reset');
  _writeln(_dim + headerBar + _reset);

  if (rows.isEmpty) {
    _writeln('  $_dim(empty)$_reset');
  } else {
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final isSelected = i == selected;

      final icon = row.isFolder ? '📂' : '📄';
      String sizeHint = '';
      if (!row.isFolder && row.fileSize != null) {
        sizeHint = '  $_dim${_formatSize(row.fileSize!)}$_reset';
      }

      if (isSelected) {
        _write(
          '$_bold${_fg(230)}${_bg(100)} › $icon  ${row.name}$_reset$sizeHint$_clearEol',
        );
      } else {
        _write('    $icon  ${row.name}$sizeHint');
      }
      _writeln();
    }
  }

  _writeln();
  _writeln(_dim + headerBar + _reset);

  // Status / help bar
  if (statusMessage != null) {
    _writeln('  ${_fg(226)}$statusMessage$_reset');
  } else {
    _writeln(
      '  $_dim U/D navigate   Enter open/download'
      '   B/Backspace back   Q quit$_reset',
    );
  }
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

// ─── Main ────────────────────────────────────────────────────────────────────

Future<void> main() async {
  // Force ANSI on Windows (Dart 3+ enables this automatically, but be safe).
  if (Platform.isWindows) {
    stdout.supportsAnsiEscapes; // access to trigger detection
  }

  final creds = PathCredentials();

  _write(_hideCursor);
  _writeln('Connecting as ${creds.username} …');

  SmartschoolClient? client;
  try {
    client = await SmartschoolClient.create(creds);
    await client.ensureAuthenticated();
  } catch (e) {
    _write(_showCursor);
    stderr.writeln('Authentication failed: $e');
    exit(1);
  }

  final intradesk = IntradeskService(client);

  // ── Navigation state ──────────────────────────────────────────────────────
  // Stack of levels we have navigated into (starts at root).
  final stack = <_Level>[
    const _Level(name: '/', folderId: null, selectedIndex: 0),
  ];
  var rows = <_Row>[];
  var selected = 0;
  String? statusMessage;

  // Load the initial listing.
  Future<void> loadListing() async {
    final level = stack.last;
    IntradeskListing listing;
    if (level.folderId == null) {
      listing = await intradesk.getRootListing();
    } else {
      listing = await intradesk.getFolderListing(level.folderId!);
    }

    rows = [
      for (final f in listing.folders)
        _Row(isFolder: true, name: f.name, id: f.id),
      for (final f in listing.files)
        _Row(
          isFolder: false,
          name: f.name,
          id: f.id,
          fileSize: f.currentRevision?.fileSize,
        ),
    ];
    selected = selected.clamp(0, rows.isEmpty ? 0 : rows.length - 1);
  }

  await loadListing();

  // ── Terminal raw-mode input loop ──────────────────────────────────────────
  if (stdin.hasTerminal) {
    stdin.echoMode = false;
    stdin.lineMode = false;
  }

  int width() => stdout.hasTerminal ? stdout.terminalColumns : 80;

  void render() {
    _renderScreen(
      stack: stack,
      rows: rows,
      selected: selected,
      terminalWidth: width(),
      statusMessage: statusMessage,
    );
  }

  render();

  try {
    await for (final chunk in stdin) {
      final key = chunk.toList();
      statusMessage = null; // clear status on any key
      var done = false;

      if (_match(key, _kUp1) || _match(key, _kUp2)) {
        if (rows.isNotEmpty) {
          selected = (selected - 1).clamp(0, rows.length - 1);
        }
      } else if (_match(key, _kDown1) || _match(key, _kDown2)) {
        if (rows.isNotEmpty) {
          selected = (selected + 1).clamp(0, rows.length - 1);
        }
      } else if (_match(key, _kQ1) || _match(key, _kQ2)) {
        done = true;
      } else if (_match(key, _kBack1) ||
          _match(key, _kBack2) ||
          _match(key, _kBackspace1) ||
          _match(key, _kBackspace2)) {
        // Go back up one level (but not past root).
        if (stack.length > 1) {
          final popped = stack.removeLast();
          selected = popped.selectedIndex; // restore previous position
          await _withStatus(
            render,
            () => loadListing(),
            onMessage: (m) => statusMessage = m,
          );
        }
      } else if (_match(key, _kEnter1) || _match(key, _kEnter2)) {
        if (rows.isNotEmpty) {
          final row = rows[selected];
          if (row.isFolder) {
            // Navigate into the folder.
            stack.add(
              _Level(name: row.name, folderId: row.id, selectedIndex: selected),
            );
            selected = 0;
            await _withStatus(
              render,
              () => loadListing(),
              onMessage: (m) => statusMessage = m,
            );
          } else {
            // Download the file.
            statusMessage = 'Downloading ${row.name} …';
            render();
            try {
              final Uint8List bytes = await intradesk.downloadFile(row.id);
              final outFile = File(row.name);
              await outFile.writeAsBytes(bytes);
              statusMessage =
                  '✓  Saved ${row.name}  (${_formatSize(bytes.length)})'
                  '  →  ${outFile.absolute.path}';
            } catch (e) {
              statusMessage = '✗  Download failed: $e';
            }
          }
        }
      }

      render();
      if (done) break;
    }
  } finally {
    if (stdin.hasTerminal) {
      stdin.echoMode = true;
      stdin.lineMode = true;
    }
    _write(_showCursor);
    _write(_clearScreen);
    _writeln('Bye!');
  }
}

// ─── Utilities ───────────────────────────────────────────────────────────────

bool _match(List<int> actual, List<int> expected) {
  if (actual.length < expected.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (actual[i] != expected[i]) return false;
  }
  return true;
}

/// Renders a one-line loading indicator while [work] runs, then calls [render].
Future<void> _withStatus(
  void Function() render,
  Future<void> Function() work, {
  required void Function(String?) onMessage,
}) async {
  onMessage('Loading …');
  render();
  try {
    await work();
    onMessage(null);
  } catch (e) {
    onMessage('Error: $e');
  }
}
