import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'exceptions.dart';

// ---------------------------------------------------------------------------
// Abstract base
// ---------------------------------------------------------------------------

/// Provides the credentials needed to authenticate with Smartschool.
///
/// Replaces the Python base class which used class-level attributes as a
/// mutable namespace — here it is a proper abstract class with read-only
/// getters, making the contract explicit and immutable.
abstract class Credentials {
  String get username;
  String get password;

  /// The Smartschool hostname without scheme, e.g. `school.smartschool.be`.
  String get mainUrl;

  /// Optional MFA secret.
  ///
  /// - For **account-verification** (birthday-based): a date string like
  ///   `2010-05-15`.
  /// - For **2FA / TOTP**: the Base32 secret from Google Authenticator: the
  ///   key Smartschool shows when an authenticator app is added, not the
  ///   6-digit code the app shows. It may be copied in groups, with spaces or
  ///   hyphens, in lower case or with `=` padding (see
  ///   [normalizeTotpSecret]).
  ///
  /// An `mfa` that is empty once trimmed counts as none. When a login is
  /// needed and `mfa` is neither that, a date (`yyyy-mm-dd`), nor a TOTP
  /// secret, the login throws a [SmartschoolInvalidTotpSecretError] before it
  /// posts the password (#79).
  String? get mfa;

  /// Returns the TOTP secret [secret] the way the login generates its 2FA
  /// codes from it: without white space and hyphens (an authenticator setup
  /// screen may show the key in groups, such as `JBSW Y3DP EHPK 3PXP`), in
  /// upper case, and without `=` padding.
  ///
  /// Throws a [SmartschoolInvalidTotpSecretError] when that is not a TOTP
  /// secret: empty, with a character that is not Base32 (the letters A-Z and
  /// the digits 2-7, with `=` padding only at the end), or only digits, such
  /// as the 6-digit code an authenticator app shows rather than the key it
  /// was set up with (#79). Its message does not hold [secret].
  ///
  /// The login applies it to [mfa]. Call it to check a key without logging
  /// in, for instance where a user enters it.
  static String normalizeTotpSecret(String secret) {
    final key = secret.replaceAll(_totpSecretSeparators, '');
    // Checked before upper-casing: that maps some other letters onto Base32
    // ones (`ß` becomes `SS`).
    if (!_base32Key.hasMatch(key) || _digitsOnly.hasMatch(key)) {
      throw const SmartschoolInvalidTotpSecretError();
    }
    return key.toUpperCase().replaceFirst(_base32Padding, '');
  }

  /// What a TOTP secret may be copied with that is not part of it: white
  /// space (Unicode white space, so a non-breaking space of a web page too)
  /// and hyphens.
  static final _totpSecretSeparators = RegExp(r'[\s-]');

  /// Base32 (RFC 4648) in either case, with any `=` padding at the end.
  static final _base32Key = RegExp(r'^[A-Za-z2-7]+=*$');

  /// The `=` padding at the end of a Base32 key.
  static final _base32Padding = RegExp(r'=+$');

  /// Only digits: a code (or a date), not a key. A Base32 key of only the
  /// digits 2-7 is possible, but a random secret is next to never one.
  static final _digitsOnly = RegExp(r'^[0-9]+=*$');

  /// Throws [StateError] if any required field is empty after trimming.
  void validate() {
    final errors = <String>[];
    if (username.trim().isEmpty) errors.add('username');
    if (password.trim().isEmpty) errors.add('password');
    if (mainUrl.trim().isEmpty) errors.add('mainUrl');
    if (errors.isNotEmpty) {
      throw StateError('Missing or empty required credential fields: $errors');
    }
  }
}

// ---------------------------------------------------------------------------
// AppCredentials — primary class for Flutter apps
// ---------------------------------------------------------------------------

/// Credentials supplied directly in code or from app configuration.
///
/// This is the easiest class to use from a Flutter application:
/// ```dart
/// final creds = AppCredentials(
///   username: 'john.doe',
///   password: 's3cr3t',
///   mainUrl: 'school.smartschool.be',
/// );
/// ```
class AppCredentials extends Credentials {
  @override
  final String username;

  @override
  final String password;

  @override
  final String mainUrl;

  @override
  final String? mfa;

  AppCredentials({
    required this.username,
    required this.password,
    required this.mainUrl,
    this.mfa,
  }) {
    assert(username.trim().isNotEmpty, 'username must not be empty');
    assert(password.trim().isNotEmpty, 'password must not be empty');
    assert(mainUrl.trim().isNotEmpty, 'mainUrl must not be empty');
  }
}

// ---------------------------------------------------------------------------
// EnvCredentials — reads from environment variables
// ---------------------------------------------------------------------------

/// Credentials loaded from well-known environment variables.
///
/// Variables used:
/// - `SMARTSCHOOL_USERNAME`
/// - `SMARTSCHOOL_PASSWORD`
/// - `SMARTSCHOOL_MAIN_URL`
/// - `SMARTSCHOOL_MFA` *(optional)*
class EnvCredentials extends Credentials {
  @override
  String get username => Platform.environment['SMARTSCHOOL_USERNAME'] ?? '';

  @override
  String get password => Platform.environment['SMARTSCHOOL_PASSWORD'] ?? '';

  @override
  String get mainUrl => Platform.environment['SMARTSCHOOL_MAIN_URL'] ?? '';

  @override
  String? get mfa => Platform.environment['SMARTSCHOOL_MFA'];
}

// ---------------------------------------------------------------------------
// PathCredentials — reads from a YAML file on disk
// ---------------------------------------------------------------------------

/// Credentials loaded from a `credentials.yml` file on the filesystem.
///
/// The YAML file must contain the keys `username`, `password`, `main_url`,
/// and optionally `mfa`:
/// ```yaml
/// username: john.doe
/// password: s3cr3t
/// main_url: school.smartschool.be
/// mfa: 2010-05-15
/// ```
///
/// The file is searched in the following order:
/// 1. The exact [filename] path (if provided).
/// 2. The current working directory.
/// 3. Each parent directory up to the filesystem root.
/// 4. The user's home directory.
/// 5. `~/.cache/smartschool/credentials.yml`.
class PathCredentials extends Credentials {
  @override
  late final String username;

  @override
  late final String password;

  @override
  late final String mainUrl;

  @override
  late final String? mfa;

  static const _defaultFilename = 'credentials.yml';

  PathCredentials({String? filename}) {
    final file = _findCredentialsFile(filename);
    final raw = file.readAsStringSync();
    final yaml = loadYaml(raw) as YamlMap;

    username = (yaml['username'] ?? '').toString().trim();
    password = (yaml['password'] ?? '').toString().trim();
    mainUrl = (yaml['main_url'] ?? '').toString().trim();
    final rawMfa = yaml['mfa'];
    mfa = rawMfa?.toString().trim();
  }

  static File _findCredentialsFile(String? filename) {
    final candidates = <String>[];

    // Explicit path first
    if (filename != null && filename.isNotEmpty) {
      candidates.add(filename);
    }

    final cwd = Directory.current.path;
    final home = _homeDir;

    // Search from cwd upwards
    var dir = Directory(cwd);
    while (true) {
      candidates.add(p.join(dir.path, _defaultFilename));
      final parent = dir.parent;
      if (parent.path == dir.path) break; // filesystem root
      dir = parent;
    }

    candidates.addAll([
      p.join(home, _defaultFilename),
      p.join(home, '.cache', 'smartschool', _defaultFilename),
    ]);

    final seen = <String>{};
    for (final candidate in candidates) {
      if (candidate.isEmpty || !seen.add(candidate)) continue;
      final file = File(candidate);
      if (file.existsSync()) return file;
    }

    throw FileSystemException(
      'credentials.yml not found in any search path',
      filename ?? _defaultFilename,
    );
  }

  static String get _homeDir =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';
}
