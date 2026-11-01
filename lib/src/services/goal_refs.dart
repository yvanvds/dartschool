import '../models/goal_models.dart';

/// The checks and comparisons of the goal writes (#223): the goals of a
/// lesfiche (`LessonContentService.changeGoals`, the creates) and, later, of
/// a planned lesson. Not exported.
abstract final class GoalRefs {
  /// A goal's ID: a UUID.
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );

  /// [goals] as a goal write sends them, in their order, after the checks:
  /// each `id` a UUID, a non-empty `leerplanId` and `type` without white
  /// space around them. A goal given twice (the same reference, the ID in
  /// any case) is kept once; two different references with the same goal
  /// ID are an [ArgumentError] for [argument], as is a goal that fails a
  /// check.
  static List<LearningGoalRef> checked(
    Iterable<LearningGoalRef> goals, {
    String argument = 'goals',
  }) {
    final byId = <String, LearningGoalRef>{};
    final result = <LearningGoalRef>[];
    for (final (index, goal) in goals.indexed) {
      final name = '$argument[$index]';
      if (!_uuid.hasMatch(goal.id)) {
        throw ArgumentError.value(goal, name, 'has an id that is not a UUID');
      }
      for (final (field, value) in [
        ('leerplanId', goal.leerplanId),
        ('type', goal.type),
      ]) {
        if (value.trim().isEmpty) {
          throw ArgumentError.value(goal, name, 'has an empty $field');
        }
        if (value.trim() != value) {
          throw ArgumentError.value(
            goal,
            name,
            'has white space around its $field',
          );
        }
      }
      final key = goal.id.toLowerCase();
      final earlier = byId[key];
      if (earlier == null) {
        byId[key] = goal;
        result.add(goal);
      } else if (!same([earlier], [goal])) {
        throw ArgumentError.value(
          goal,
          name,
          'has the id of $earlier, in another curriculum or of another type',
        );
      }
    }
    return result;
  }

  /// Whether [a] and [b] hold the same goals, in any order, the IDs in any
  /// case.
  static bool same(Iterable<LearningGoalRef> a, Iterable<LearningGoalRef> b) {
    final left = {for (final goal in a) _key(goal)};
    final right = {for (final goal in b) _key(goal)};
    return left.length == right.length && left.containsAll(right);
  }

  /// [goals] for a message: their IDs, or `none`.
  static String describe(Iterable<LearningGoalRef> goals) =>
      goals.isEmpty ? 'none' : '[${goals.map((g) => g.id).join(', ')}]';

  static (String, String, String) _key(LearningGoalRef goal) =>
      (goal.id.toLowerCase(), goal.leerplanId.toLowerCase(), goal.type);
}
