import 'dart:convert';

import '../models/lesson_content_models.dart';

/// How the Lesfiches module's failures read (#235, #244): the `violations`
/// of a problem answer, and the `exceptions` of a write of several lesfiches
/// (`LessonContentService.trash`, `restore`, `duplicate`,
/// `TeachingAssignmentService.addLessonContent`). Not exported.
abstract final class LessonContentFailures {
  /// The `violations` of the module's problem answer [body]: a list, or an
  /// object whose values are the reasons; empty when there are none (the
  /// bare `400` seen live), or when [body] is not such an answer.
  static List<String> violations(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const [];
    }
    final raw = decoded is Map ? decoded['violations'] : null;
    final Iterable<Object?> values = switch (raw) {
      final List<Object?> list => list,
      final Map<Object?, Object?> map => map.values,
      _ => const [],
    };
    return List.unmodifiable([
      for (final value in values)
        if (value != null && '$value'.trim().isNotEmpty) '$value'.trim(),
    ]);
  }

  /// One of the `exceptions` of a write of several lesfiches as a
  /// [LessonContentBulkFailure]: its `status`, and its `title`, `detail`
  /// and `violations` when it is a problem object.
  static LessonContentBulkFailure bulkFailure(Object? exception) {
    if (exception is! Map) {
      return LessonContentBulkFailure(message: '"$exception"', raw: exception);
    }
    final parts = [
      for (final key in const ['title', 'detail'])
        if ('${exception[key] ?? ''}'.trim().isNotEmpty)
          '${exception[key]}'.trim(),
      ...violations(jsonEncode(exception)),
    ];
    final status = exception['status'];
    return LessonContentBulkFailure(
      statusCode: status is int ? status : null,
      message: parts.isEmpty ? jsonEncode(exception) : parts.join(': '),
      raw: exception,
    );
  }
}
