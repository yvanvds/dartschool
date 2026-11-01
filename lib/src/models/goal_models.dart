import 'package:html/parser.dart' as html_parser;

import '../exceptions.dart';

/// Where Smartschool's goal selector is opened (#222): the first part of
/// every route of `/goal/selector/api/v1/leerplannen/`. Both list the same
/// curricula (seen live, 2026-11-01); the selector names the place it picks
/// goals for.
enum GoalLocation {
  /// The Lesfiches module (`lesson-content`): the goals of a lesfiche.
  lessonContent('lesson-content'),

  /// The planner (`planner-lesson-content`): the goals of a planned lesson.
  plannerLessonContent('planner-lesson-content');

  /// The name in the route.
  final String wireName;

  const GoalLocation(this.wireName);
}

/// A reference to a learning goal, as a lesfiche or a planned lesson stores
/// it (`{"id", "leerplanId", "type"}`, #222): what `GoalService.resolve`
/// names, and what the goal writes of the Lesfiches module and the planner
/// send.
///
/// For a goal of the goal selector, [type] is the curriculum's
/// `leerplanType` ([Curriculum.leerplanType], such as
/// `eindtermen-derde-graad-doorstroom` or `miniDB`); goals of other sources
/// have their source there (`llinkid`, `zill`, ...). [SelectableGoal.ref]
/// makes one from a goal of a [Curriculum].
class LearningGoalRef {
  /// The goal's ID ([CurriculumNode.id]).
  final String id;

  /// The ID of the goal's curriculum ([Curriculum.id]).
  final String leerplanId;

  /// The curriculum's `leerplanType`, or the goal's source.
  final String type;

  const LearningGoalRef({
    required this.id,
    required this.leerplanId,
    required this.type,
  });

  /// Parses a stored goal (`{"id", "leerplanId", "type"}`). Throws a
  /// [FormatException] when one of the three is not a non-empty string.
  factory LearningGoalRef.fromJson(Map<String, dynamic> json) {
    String field(String key) {
      final value = json[key];
      if (value is String && value.isNotEmpty) return value;
      throw FormatException('A learning goal without its "$key": $json');
    }

    return LearningGoalRef(
      id: field('id'),
      leerplanId: field('leerplanId'),
      type: field('type'),
    );
  }

  /// The goal as it is stored: `{"id", "leerplanId", "type"}`.
  Map<String, String> toJson() => {
    'id': id,
    'leerplanId': leerplanId,
    'type': type,
  };

  /// The goal as Smartschool's web clients send it, to the goal selector and
  /// in a goal write: `{"id", "goalId", "leerplanId", "type"}`, with
  /// `goalId` the same as `id`.
  Map<String, String> toWire() => {
    'id': id,
    'goalId': id,
    'leerplanId': leerplanId,
    'type': type,
  };

  @override
  bool operator ==(Object other) =>
      other is LearningGoalRef &&
      other.id == id &&
      other.leerplanId == leerplanId &&
      other.type == type;

  @override
  int get hashCode => Object.hash(id, leerplanId, type);

  @override
  String toString() => 'LearningGoalRef($type $leerplanId $id)';
}

/// A group of curricula in the goal selector's list (#222), such as
/// `Overheid SO` (the eindtermen), `Levensbeschouwing SO`, `Andere SO` or
/// `Minidatabanken` (the school's own mini-databases).
class CurriculumGroup {
  /// The group's name, as the selector shows it.
  final String name;

  /// The curricula of the group, in the selector's order.
  final List<CurriculumListItem> curricula;

  const CurriculumGroup({required this.name, required this.curricula});

  /// Parses a group (`{"name", "leerplanListItems": [...]}`). Throws a
  /// [SmartschoolGoalError] for a group in another shape.
  factory CurriculumGroup.fromJson(Map<String, dynamic> json) {
    final items = json['leerplanListItems'];
    if (items is! List) {
      throw SmartschoolGoalError(
        'The goal selector gave a group of curricula without its '
        '"leerplanListItems" list.',
      );
    }
    return CurriculumGroup(
      name: json['name'] is String ? json['name'] as String : '',
      curricula: List.unmodifiable([
        for (final (index, item) in items.indexed)
          if (item is Map<String, dynamic>)
            CurriculumListItem.fromJson(item)
          else
            throw SmartschoolGoalError(
              'The goal selector gave curriculum $index of a group as '
              '${item.runtimeType} instead of an object.',
            ),
      ]),
    );
  }
}

/// A curriculum in the goal selector's list (#222): its ID, to read it with
/// `GoalService.getCurriculum`, and its title.
class CurriculumListItem {
  /// The curriculum's ID (a UUID).
  final String id;

  /// The curriculum's title, as plain text.
  final String title;

  /// The selector's icon of the curriculum (`component_green`, `laptop`),
  /// or `null`.
  final String? icon;

  /// Whether the selector shows the curriculum (`metadata.isVisible`;
  /// `true` when it does not say).
  final bool isVisible;

  /// Whether the user marked it as a favourite (`metadata.isFavourite`).
  final bool isFavourite;

  const CurriculumListItem({
    required this.id,
    required this.title,
    this.icon,
    this.isVisible = true,
    this.isFavourite = false,
  });

  /// Parses an item (`{"id", "title", "metadata": {"icon", "isVisible",
  /// "isFavourite"}}`). Throws a [SmartschoolGoalError] without an `id`.
  factory CurriculumListItem.fromJson(Map<String, dynamic> json) {
    final metadata = json['metadata'];
    final meta = metadata is Map<String, dynamic>
        ? metadata
        : const <String, dynamic>{};
    return CurriculumListItem(
      id: _requiredId(json, 'a curriculum of the list'),
      title: json['title'] is String ? json['title'] as String : '',
      icon: meta['icon'] is String ? meta['icon'] as String : null,
      isVisible: meta['isVisible'] != false,
      isFavourite: meta['isFavourite'] == true,
    );
  }
}

/// The kind of a node of a curriculum tree (#222).
enum CurriculumNodeType {
  /// A heading (`title`), such as a domain of the eindtermen.
  title('title'),

  /// A heading under a [title] (`subtitle`), as in a mini-database.
  subtitle('subtitle'),

  /// A part (`part`).
  part('part'),

  /// A part of a [part] (`subpart`).
  subpart('subpart'),

  /// A learning goal (`goal`).
  goal('goal'),

  /// A goal of basic literacy (`goal-basic`, "basisgeletterdheid"), as the
  /// eindtermen of the first grade have them (seen live, 2026-11-01).
  goalBasic('goal-basic'),

  /// An extension goal (`goal-extension`, "uitbreidingsdoel"), as the
  /// eindtermen of the first grade have them (seen live, 2026-11-01).
  goalExtension('goal-extension'),

  /// A kind the library does not know: its name is in
  /// [CurriculumNode.typeName].
  other('');

  /// The kind as the selector names it; empty for [other].
  final String wireName;

  const CurriculumNodeType(this.wireName);

  /// Whether the kind is one of the goals: [goal], [goalBasic] or
  /// [goalExtension].
  bool get isGoal => this == goal || this == goalBasic || this == goalExtension;

  static CurriculumNodeType _parse(String name) {
    for (final type in values) {
      if (type != other && type.wireName == name) return type;
    }
    return other;
  }
}

/// A node of a curriculum tree (#222): a heading, a part or a learning
/// goal, with the nodes under it.
class CurriculumNode {
  /// The node's ID; for a goal, the [LearningGoalRef.id].
  final String id;

  /// The kind of node; [CurriculumNodeType.other] for one the library does
  /// not know.
  final CurriculumNodeType type;

  /// The kind as the selector names it (`title`, `goal`, ...), also for an
  /// [CurriculumNodeType.other].
  final String typeName;

  /// The node's title as the selector gives it: HTML for the eindtermen
  /// (`<p>De leerlingen ...</p>`), plain text for a mini-database. [text]
  /// gives it as plain text.
  final String title;

  /// The node's number as the selector shows it before the title
  /// (`metadata.prefix`, such as `01.02` or `GFL 16`); `null` when it has
  /// none (an empty prefix too).
  final String? prefix;

  /// `metadata.number`, when the selector gives it (a mini-database does;
  /// the eindtermen do not); `null` otherwise or when empty.
  final String? number;

  /// The selector's icon of the node, or `null`.
  final String? icon;

  /// Whether the curriculum marks the node as deprecated
  /// (`metadata.isDeprecated`; `false` when it does not say).
  final bool isDeprecated;

  /// The nodes under this one, in the selector's order.
  final List<CurriculumNode> children;

  const CurriculumNode({
    required this.id,
    required this.type,
    required this.typeName,
    required this.title,
    this.prefix,
    this.number,
    this.icon,
    this.isDeprecated = false,
    this.children = const [],
  });

  /// Parses a node and the nodes under it. Its `metadata` may be `null`
  /// (seen live for the headings of the eindtermen). Throws a
  /// [SmartschoolGoalError] for a node without an `id` or `type`, or with
  /// `children` that are not a list of objects.
  factory CurriculumNode.fromJson(Map<String, dynamic> json) {
    final metadata = json['metadata'];
    final meta = metadata is Map<String, dynamic>
        ? metadata
        : const <String, dynamic>{};
    final typeName = json['type'];
    if (typeName is! String || typeName.isEmpty) {
      throw SmartschoolGoalError(
        'The goal selector gave a node of a curriculum without its "type".',
      );
    }
    return CurriculumNode(
      id: _requiredId(json, 'a node of a curriculum'),
      type: CurriculumNodeType._parse(typeName),
      typeName: typeName,
      title: json['title'] is String ? json['title'] as String : '',
      prefix: _nonEmpty(meta['prefix']),
      number: _nonEmpty(meta['number']),
      icon: _nonEmpty(meta['icon']),
      isDeprecated: meta['isDeprecated'] == true,
      children: _nodes(json['children']),
    );
  }

  /// Whether the node is a learning goal of one of the kinds the library
  /// knows ([CurriculumNodeType.isGoal]). The nodes a user may pick are
  /// those of [Curriculum.selectableTypes]: see [Curriculum.goals].
  bool get isGoal => type.isGoal;

  /// [title] as plain text: without its HTML tags, entities decoded,
  /// white space collapsed.
  String get text => htmlToText(title);

  /// [html] as plain text: without its tags, entities decoded, white space
  /// collapsed and trimmed.
  static String htmlToText(String html) {
    if (!html.contains('<') && !html.contains('&')) {
      return html.replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    final text = html_parser.parseFragment(html).text ?? '';
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  @override
  String toString() => 'CurriculumNode($typeName $id)';
}

/// A curriculum of the goal selector as a tree (#222): from
/// `GoalService.getCurriculum` whole, from `GoalService.resolve` pruned to
/// the goals asked for and the nodes above them.
///
/// The eindtermen have headings ([CurriculumNodeType.title]) with goals
/// under them, each with its number in [CurriculumNode.prefix] and its
/// title in HTML; a mini-database of the school has headings, subheadings
/// ([CurriculumNodeType.subtitle]) and goals, in plain text. [goals] lists
/// the goals that can be picked, with the headings above each.
class Curriculum {
  /// The curriculum's ID: the [LearningGoalRef.leerplanId] of its goals.
  final String id;

  /// The curriculum's type as the root gives it (`type`).
  final String type;

  /// The curriculum's `leerplanType` (`config.leerplanType`, such as
  /// `eindtermen-derde-graad-doorstroom` or `miniDB`; [type] when the
  /// config lacks it): the [LearningGoalRef.type] of its goals.
  final String leerplanType;

  /// The curriculum's title, as plain text.
  final String title;

  /// Whether the curriculum is deprecated (`metadata.isDeprecated`).
  final bool isDeprecated;

  /// The kinds of node the selector lets a user pick
  /// (`config.typesThatCanBeSelected`, [CurriculumNode.typeName]s; `["goal"]`
  /// when it does not say). The eindtermen of the first grade add
  /// `goal-basic` and `goal-extension` (seen live, 2026-11-01).
  final List<String> selectableTypes;

  /// The nodes at the top of the tree, in the selector's order.
  final List<CurriculumNode> children;

  const Curriculum({
    required this.id,
    required this.type,
    required this.leerplanType,
    required this.title,
    this.isDeprecated = false,
    this.selectableTypes = const ['goal'],
    this.children = const [],
  });

  /// Parses a curriculum tree. Throws a [SmartschoolGoalError] for one
  /// without an `id`, or a node in an unknown shape.
  factory Curriculum.fromJson(Map<String, dynamic> json) {
    final metadata = json['metadata'];
    final config = json['config'];
    final conf = config is Map<String, dynamic>
        ? config
        : const <String, dynamic>{};
    final type = json['type'] is String ? json['type'] as String : '';
    final selectable = conf['typesThatCanBeSelected'];
    return Curriculum(
      id: _requiredId(json, 'a curriculum'),
      type: type,
      leerplanType: _nonEmpty(conf['leerplanType']) ?? type,
      title: json['title'] is String ? json['title'] as String : '',
      isDeprecated:
          metadata is Map<String, dynamic> && metadata['isDeprecated'] == true,
      selectableTypes: selectable is List
          ? List.unmodifiable(selectable.whereType<String>())
          : const ['goal'],
      children: _nodes(json['children']),
    );
  }

  /// The nodes that can be picked ([selectableTypes]: the goals), depth
  /// first in the selector's order, each with the nodes above it. Deprecated
  /// goals are among them ([CurriculumNode.isDeprecated]).
  List<SelectableGoal> get goals {
    final found = <SelectableGoal>[];
    void walk(List<CurriculumNode> nodes, List<CurriculumNode> path) {
      for (final node in nodes) {
        if (selectableTypes.contains(node.typeName)) {
          found.add(
            SelectableGoal(
              curriculum: this,
              node: node,
              path: List.unmodifiable(path),
            ),
          );
        }
        walk(node.children, [...path, node]);
      }
    }

    walk(children, const []);
    return List.unmodifiable(found);
  }

  /// The goal [id] of [goals], or `null` when the tree does not have it.
  SelectableGoal? goal(String id) {
    for (final goal in goals) {
      if (goal.node.id == id) return goal;
    }
    return null;
  }

  @override
  String toString() => 'Curriculum($leerplanType $id)';
}

/// A goal of a [Curriculum] that can be picked (#222): the node, the nodes
/// above it (headings, parts), and the reference to store.
class SelectableGoal {
  /// The curriculum of the goal.
  final Curriculum curriculum;

  /// The goal itself.
  final CurriculumNode node;

  /// The nodes above the goal, from the top of the tree down; not the
  /// curriculum.
  final List<CurriculumNode> path;

  const SelectableGoal({
    required this.curriculum,
    required this.node,
    required this.path,
  });

  /// The reference a lesfiche or a planned lesson stores for the goal: its
  /// [CurriculumNode.id], the [Curriculum.id] and the
  /// [Curriculum.leerplanType].
  LearningGoalRef get ref => LearningGoalRef(
    id: node.id,
    leerplanId: curriculum.id,
    type: curriculum.leerplanType,
  );

  /// The plain-text titles of [path] and of the goal, from the top down.
  List<String> get titles => [for (final n in path) n.text, node.text];

  @override
  String toString() => 'SelectableGoal(${node.id})';
}

String _requiredId(Map<String, dynamic> json, String what) {
  final id = json['id'];
  if (id is String && id.isNotEmpty) return id;
  throw SmartschoolGoalError('The goal selector gave $what without its "id".');
}

String? _nonEmpty(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

List<CurriculumNode> _nodes(Object? children) {
  if (children == null) return const [];
  if (children is! List) {
    throw SmartschoolGoalError(
      'The goal selector gave the "children" of a node as '
      '${children.runtimeType} instead of a list.',
    );
  }
  return List.unmodifiable([
    for (final (index, child) in children.indexed)
      if (child is Map<String, dynamic>)
        CurriculumNode.fromJson(child)
      else
        throw SmartschoolGoalError(
          'The goal selector gave child $index of a node as '
          '${child.runtimeType} instead of an object.',
        ),
  ]);
}
