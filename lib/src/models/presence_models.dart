/// Models for the Smartschool Presence (attendance) module.
///
/// The Presence module is an **internal** Smartschool subsystem — it is not
/// part of the official/public API and speaks Smartschool's internal `userID`
/// (not the public `AccountID` / `RegisterID` / `UID`). Callers therefore
/// supply the internal `userID` and the class `groupID` themselves.
library;

/// Which half of the school day a presence entry applies to.
///
/// Smartschool's Presence module tracks two half-day cells per pupil per day,
/// keyed by [wire] value `"am"` (morning) or `"pm"` (afternoon). Per-lesson
/// rows use `partOfDay: "none"` and are ignored by this library.
enum DayPart {
  /// The morning half-day (`"am"`).
  morning('am'),

  /// The afternoon half-day (`"pm"`).
  afternoon('pm');

  const DayPart(this.wire);

  /// The value Smartschool's Presence API uses for this half-day.
  final String wire;

  /// Resolves a [DayPart] from its Smartschool wire value (`"am"` / `"pm"`).
  ///
  /// Returns `null` for any other value (e.g. `"none"`, used by per-lesson
  /// presence rows rather than half-day cells).
  static DayPart? fromWire(String? wire) {
    switch (wire) {
      case 'am':
        return DayPart.morning;
      case 'pm':
        return DayPart.afternoon;
      default:
        return null;
    }
  }
}

/// A class as listed by the Presence module's config (`Presence/Main/getConfig`).
///
/// Official teaching classes carry a real [structId] / [adminNumber]; virtual
/// grouping classes (which only aggregate down-stream groups) report empty
/// values for those, which are parsed here as `null`.
class PresenceClassRef {
  /// Presence "groupID" of the class — the identifier callers pass as
  /// `classGroupId`.
  final int groupId;

  /// Display name of the class (e.g. `"1A"`). Trailing padding whitespace from
  /// the server is trimmed.
  final String name;

  /// Official administration number, or `null` for a virtual grouping class.
  ///
  /// Classes map cleanly to the public API by this number.
  final int? adminNumber;

  /// Official institute number, or `null` for a virtual grouping class.
  final int? instituteNumber;

  /// School "structure" ID — required to resolve presence codes, or `null` for
  /// a virtual grouping class.
  final int? structId;

  /// Whether the signed-in account may record presences for this class.
  final bool userCanRecord;

  /// Whether the signed-in account may confirm presences for this class.
  final bool userCanConfirm;

  /// Whether this is an official (administratively recognised) class.
  final bool isOfficial;

  const PresenceClassRef({
    required this.groupId,
    required this.name,
    this.adminNumber,
    this.instituteNumber,
    this.structId,
    this.userCanRecord = false,
    this.userCanConfirm = false,
    this.isOfficial = false,
  });

  factory PresenceClassRef.fromJson(Map<String, dynamic> json) {
    return PresenceClassRef(
      groupId: _asInt(json['groupID']) ?? 0,
      name: (json['name'] as String? ?? '').trim(),
      adminNumber: _asInt(json['adminNumber']),
      instituteNumber: _asInt(json['instituteNumber']),
      structId: _asInt(json['structID']),
      userCanRecord: json['userCanRecord'] == true,
      userCanConfirm: json['userCanConfirm'] == true,
      isOfficial: _asInt(json['isOfficial']) == 1 || json['isOfficial'] == true,
    );
  }

  @override
  String toString() =>
      'PresenceClassRef(groupId: $groupId, name: $name, structId: $structId)';
}

/// The Presence module configuration for the signed-in account.
///
/// Parsed from `Presence/Main/getConfig`. Provides the schoolyear reference
/// date (needed by `getClass`) and the classes the account may work with.
class PresenceConfig {
  /// The currently active class in the Presence UI (may be `null`).
  final PresenceClassRef? activeClass;

  /// All classes the account is allowed to view/record.
  final List<PresenceClassRef> allowedClasses;

  /// The schoolyear reference date (`state.schoolyear`, `yyyy-MM-dd`), passed
  /// to `getClass` as `schoolyearRefDate`.
  final String schoolyearRefDate;

  const PresenceConfig({
    required this.activeClass,
    required this.allowedClasses,
    required this.schoolyearRefDate,
  });

  /// Returns the class with [groupId] from [allowedClasses] (falling back to
  /// [activeClass]), or `null` when the account has no such class.
  PresenceClassRef? classForGroup(int groupId) {
    for (final c in allowedClasses) {
      if (c.groupId == groupId) return c;
    }
    if (activeClass?.groupId == groupId) return activeClass;
    return null;
  }

  @override
  String toString() =>
      'PresenceConfig(schoolyearRefDate: $schoolyearRefDate, '
      'allowedClasses: ${allowedClasses.length})';
}

/// An alias of a presence code (e.g. "Te laat zonder geldige reden" is an alias
/// of the "Te laat" code).
///
/// When a presence is saved against an alias, the server stores `codeID: null`
/// and keys on [aliasId]; [parentCodeId] is the alias' owning code.
class PresenceAlias {
  /// The alias identifier (`aliasID`) — sent as `aliasID` when saving.
  final int aliasId;

  /// The owning code's ID (`codeID` on the alias record).
  final int parentCodeId;

  /// Human-readable alias name (e.g. `"Te laat zonder geldige reden"`).
  final String name;

  const PresenceAlias({
    required this.aliasId,
    required this.parentCodeId,
    required this.name,
  });

  factory PresenceAlias.fromJson(Map<String, dynamic> json) {
    return PresenceAlias(
      aliasId: _asInt(json['aliasID']) ?? 0,
      parentCodeId: _asInt(json['codeID']) ?? 0,
      name: (json['name'] as String? ?? '').trim(),
    );
  }

  @override
  String toString() => 'PresenceAlias(aliasId: $aliasId, name: $name)';
}

/// A presence/absence status code for a school structure.
///
/// Codes are **per-structure/per-school** (their numeric [codeId] is not
/// stable across schools), so they must be resolved dynamically by [name].
class PresenceCode {
  /// The code identifier (`codeID`) — sent as `codeID` when saving.
  final int codeId;

  /// Short code glyph (e.g. `"L"` for "Te laat"). May be blank.
  final String code;

  /// Human-readable status name (e.g. `"Aanwezig"`, `"Te laat"`).
  final String name;

  /// Aliases owned by this code (e.g. "Te laat zonder geldige reden").
  final List<PresenceAlias> aliases;

  const PresenceCode({
    required this.codeId,
    required this.code,
    required this.name,
    this.aliases = const [],
  });

  factory PresenceCode.fromJson(Map<String, dynamic> json) {
    final rawAliases = json['alias'];
    final aliases = <PresenceAlias>[];
    if (rawAliases is List) {
      for (final a in rawAliases) {
        if (a is Map<String, dynamic>) {
          aliases.add(PresenceAlias.fromJson(a));
        }
      }
    }
    return PresenceCode(
      codeId: _asInt(json['codeID']) ?? 0,
      code: json['code'] as String? ?? '',
      name: (json['name'] as String? ?? '').trim(),
      aliases: aliases,
    );
  }

  /// Returns the alias whose name equals [aliasName] (case-insensitive), or
  /// `null` if this code has no such alias.
  PresenceAlias? aliasByName(String aliasName) {
    final target = aliasName.trim().toLowerCase();
    for (final a in aliases) {
      if (a.name.toLowerCase() == target) return a;
    }
    return null;
  }

  @override
  String toString() =>
      'PresenceCode(codeId: $codeId, name: $name, aliases: ${aliases.length})';
}

/// A single half-day presence cell (`partOfDay: "am"|"pm"`, `hourID: null`) for
/// a pupil on a specific date.
///
/// [presenceId] is `null` when the half-day has no record yet — the "create"
/// case, where saving inserts a new cell rather than updating an existing one.
class PresenceHalfDay {
  /// The existing record id, or `null` when the cell has no record yet.
  final int? presenceId;

  /// The date of the cell (`yyyy-MM-dd`).
  final String presenceDate;

  /// Which half-day this cell represents.
  final DayPart part;

  /// The currently stored code id, or `null` (e.g. when keyed on an alias).
  final int? codeId;

  /// The currently stored alias id, or `null`.
  final int? aliasId;

  /// The currently stored motivation text.
  final String motivation;

  const PresenceHalfDay({
    required this.presenceId,
    required this.presenceDate,
    required this.part,
    required this.codeId,
    required this.aliasId,
    required this.motivation,
  });

  @override
  String toString() =>
      'PresenceHalfDay(part: ${part.wire}, presenceId: $presenceId, '
      'codeId: $codeId, aliasId: $aliasId)';
}

/// A pupil as returned by `Presence/Class/getClass`, with the resolved half-day
/// cells for the requested date range.
class PresencePupil {
  /// The pupil's internal Smartschool `userID`.
  final int userId;

  /// The pupil's `movementID` for the class/date (required when saving).
  final int movementId;

  /// The pupil's display name.
  final String name;

  /// The half-day (am/pm) presence cells found for this pupil.
  final List<PresenceHalfDay> halfDays;

  const PresencePupil({
    required this.userId,
    required this.movementId,
    required this.name,
    this.halfDays = const [],
  });

  /// Returns the half-day cell for [part] on [date] (`yyyy-MM-dd`), or `null`
  /// when the pupil has no cell for that half-day.
  ///
  /// When [date] is omitted, the first cell matching [part] is returned.
  PresenceHalfDay? halfDayFor(DayPart part, {String? date}) {
    for (final cell in halfDays) {
      if (cell.part == part && (date == null || cell.presenceDate == date)) {
        return cell;
      }
    }
    return null;
  }

  @override
  String toString() =>
      'PresencePupil(userId: $userId, movementId: $movementId, name: $name)';
}

/// Parses [value] leniently to an `int`, returning `null` for empty strings,
/// `null`, or non-numeric values.
///
/// Smartschool reports several numeric fields (`adminNumber`, `structID`, …)
/// as an empty string for virtual/aggregate classes, hence the leniency.
int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return int.tryParse(trimmed);
  }
  return null;
}
