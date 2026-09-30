import 'package:path/path.dart' as p;

/// The folder that `SmartschoolClient.create` keeps the per-user data of
/// [username] in when it is given no `cacheDir`, for the environment
/// variables in [environment] (#30).
///
/// The home folder is `HOME`, else `USERPROFILE` (Windows, where `HOME` is
/// usually not set), else the current directory (`.`); the folder is
/// `.cache/smartschool/<username>` in it.
///
/// Not exported: apps call `SmartschoolClient.defaultCacheDir`, which passes
/// `Platform.environment`. Taking the environment as an argument lets tests
/// work out the folder for any platform's variables without touching the real
/// home folder.
String defaultCacheDirFor(String username, Map<String, String> environment) {
  final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '.';
  return p.join(home, '.cache', 'smartschool', username);
}
