/// The currently authenticated Smartschool user.
class SmartschoolUser {
  final int id;
  final String displayName;
  final String? avatarUrl;

  const SmartschoolUser({
    required this.id,
    required this.displayName,
    this.avatarUrl,
  });
}
