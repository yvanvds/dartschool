import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: fetch the currently logged-in Smartschool user.
///
/// Run with:
///   dart run example/get_current_user_example.dart
Future<void> main() async {
  final creds = PathCredentials();

  print('Connecting to Smartschool as ${creds.username} …');

  final client = await SmartschoolClient.create(creds);
  await client.ensureAuthenticated();
  print('✓ Authenticated.\n');

  final user = await client.getCurrentUser();

  print('ID          : ${user.id}');
  print('Display name: ${user.displayName}');
  print('Avatar URL  : ${user.avatarUrl}');
}
