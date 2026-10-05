/// Models for the Smartschool Presence (attendance) module.
///
/// The Presence module is an **internal** Smartschool subsystem — it is not
/// part of the official/public API and speaks Smartschool's internal `userID`
/// (not the public `AccountID` / `RegisterID` / `UID`). Callers therefore
/// supply the internal `userID` and the class `groupID` themselves.
library;

import 'dart:collection';

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
/// grouping classes report empty values for those, which are parsed here as
/// `null`.
///
/// ### Grouping classes (#126)
/// Seen live (read-only, 2026-10-05, an account with the
/// absence-administrator rights): `getConfig` listed 120 classes, 103
/// official ones with the school's one structure (`isOfficial` 1, `structID`
/// 311) and 17 grouping classes (`isOfficial` 0, `structID`, `adminNumber`
/// and `instituteNumber` `""`). Six of those group official classes of a
/// year, which they name in [downStreamGroupIds] (2A: 2A MAW, 2A MOW, 2A
/// STEMW and 2A ECO); the other eleven, such as "Taalatelier groep 1" or
/// "Huiswerkatelier", name none, and their pupils come from official classes
/// across the school. `getClass` lists a grouping class's pupils with their
/// half-days, the same records (`presenceID`, `codeID`) as in their official
/// classes.
///
/// A grouping class has no structure to ask `PresenceService.getAllCodes`
/// for. Its half-days are named by the status the module gives with each
/// record ([PresenceHalfDay.statusName]), or by the codes of the structure of
/// each pupil's official class ([PresencePupil.officialClassId], whose
/// [structId] `getConfig` gives); see `PresenceService.statusNameOf`.
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
  ///
  /// For a grouping class, name the statuses of its half-days with
  /// [PresenceHalfDay.statusName], or with the codes of the structure of each
  /// pupil's official class ([PresencePupil.officialClassId]) (#126).
  final int? structId;

  /// The `groupID`s of the classes this class groups (the module's
  /// `downStreamGroups`), or empty when it names none (#126).
  ///
  /// Seen live (read-only, 2026-10-05): empty for every official class; for
  /// six of the school's seventeen grouping classes, the official classes of
  /// a year it groups (2A: the `groupID`s of 2A MAW, 2A MOW, 2A STEMW and 2A
  /// ECO); empty for the other grouping classes, whose pupils come from
  /// official classes across the school. It is not the list of the official
  /// classes of its pupils: the grouping class 2C listed a pupil whose
  /// official class ([PresencePupil.officialClassId]) is 2E ECO, which it
  /// does not name. For the codes of a pupil's half-day, take the pupil's
  /// official class.
  final List<int> downStreamGroupIds;

  /// The module's `userCanRecord` ("registreren") for this class: **not** the
  /// right to set a half-day, which is [userCanConfirm] (#121).
  ///
  /// Seen live (2026-10-04): a teacher account without the
  /// absence-administrator rights has it `true` for every class `getConfig`
  /// lists, and `getClass` lists the class's pupils and half-days for it, but
  /// the module refuses that account's half-day save. What it does grant was
  /// not established; it looks like the registration per lesson, which this
  /// library does not do. Do not gate `setLate` / `setPresent` on it.
  final bool userCanRecord;

  /// Whether the signed-in account may set the half-days of this class (the
  /// module's `userCanConfirm`, "bevestigen"): the right `setLate` and
  /// `setPresent` need (#121).
  ///
  /// Seen live (2026-10-04, one teacher account): with its
  /// absence-administrator rights switched off, `false` for every class
  /// `getConfig` listed (88), and the module refused a half-day save with
  /// "U heeft geen rechten om afwezigheden te bevestigen voor deze leerling.
  /// Contacteer uw beheerder."; with them on, `true` for every class (120).
  /// `setLate` and `setPresent` refuse a class without it before they send
  /// anything, with a `SmartschoolPresenceNoConfirmRightError`. Gate a write
  /// on this flag, not on [userCanRecord].
  final bool userCanConfirm;

  /// Whether this is an official (administratively recognised) class.
  final bool isOfficial;

  const PresenceClassRef({
    required this.groupId,
    required this.name,
    this.adminNumber,
    this.instituteNumber,
    this.structId,
    this.downStreamGroupIds = const [],
    this.userCanRecord = false,
    this.userCanConfirm = false,
    this.isOfficial = false,
  });

  /// Whether this is no class but a placeholder the Presence module gives in
  /// the place of one (#117): its [groupId] is below 1.
  ///
  /// Seen live (read-only, 2026-10-03): the class `-2`, "Uit Planner",
  /// without a [structId], which the module gives as the active class of a
  /// teacher who has no lesson at that moment. `getClass` lists no pupils
  /// for it ("U geeft momenteel geen les. Kies een andere klas in de
  /// keuzelijst."), and names no class. A class of the module has a
  /// `groupID` of 1 or more; one read without a `groupID` gets `0`, which is
  /// no class either.
  ///
  /// [PresenceConfig] keeps such a placeholder apart: in
  /// [PresenceConfig.activePlaceholder], not in [PresenceConfig.activeClass],
  /// and [PresenceConfig.classForGroup] does not return it.
  bool get isPlaceholder => groupId < 1;

  factory PresenceClassRef.fromJson(Map<String, dynamic> json) {
    return PresenceClassRef(
      groupId: _asInt(json['groupID']) ?? 0,
      name: (json['name'] as String? ?? '').trim(),
      adminNumber: _asInt(json['adminNumber']),
      instituteNumber: _asInt(json['instituteNumber']),
      structId: _asInt(json['structID']),
      downStreamGroupIds: _asIntList(json['downStreamGroups']),
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
  /// The class active in the Presence module's web client (its
  /// `state.activeClass`), or `null` when there is none.
  ///
  /// Also `null` when the module gives a placeholder there instead of a
  /// class (#117): the class `-2`, "Uit Planner", for a teacher who has no
  /// lesson at that moment (see [PresenceClassRef.isPlaceholder]). That
  /// placeholder is [activePlaceholder]. So a list of the account's classes
  /// as [classForGroup] finds them, [allowedClasses] plus [activeClass] when
  /// it is not among them, lists no placeholder.
  ///
  /// `PresenceService.parseConfig` sorts the module's active class into this
  /// field or [activePlaceholder]; a [PresenceConfig] built by hand keeps
  /// what it is given, but [classForGroup] never returns a placeholder.
  final PresenceClassRef? activeClass;

  /// The placeholder the Presence module gives as its active class instead
  /// of a class (#117), or `null` when it gives a class ([activeClass]) or
  /// nothing.
  ///
  /// Seen live: the class `-2`, "Uit Planner", for a teacher who has no
  /// lesson at that moment ([PresenceClassRef.isPlaceholder]). It is no
  /// class: `getClass` lists no pupils for it, and [classForGroup] does not
  /// return it.
  final PresenceClassRef? activePlaceholder;

  /// All classes the account is allowed to view/record.
  ///
  /// Which classes are listed depends on the account's rights too (#121):
  /// seen live (2026-10-04), one account listed 88 classes with its
  /// absence-administrator rights switched off and 120 with them on (more
  /// sub-groups, such as "2A ECO", and groups outside the school structure).
  /// [PresenceClassRef.userCanConfirm] tells, per class, whether the account
  /// may set its half-days.
  final List<PresenceClassRef> allowedClasses;

  /// The schoolyear reference date (`state.schoolyear`, `yyyy-MM-dd`), passed
  /// to `getClass` as `schoolyearRefDate`.
  final String schoolyearRefDate;

  const PresenceConfig({
    required this.activeClass,
    required this.allowedClasses,
    required this.schoolyearRefDate,
    this.activePlaceholder,
  });

  /// Returns the class with [groupId] from [allowedClasses] (falling back to
  /// [activeClass]), or `null` when the account has no such class.
  ///
  /// Never a placeholder (#117): `null` for the `groupId` of
  /// [activePlaceholder], such as `-2` ("Uit Planner"), and for any other
  /// `groupId` below 1 ([PresenceClassRef.isPlaceholder]).
  PresenceClassRef? classForGroup(int groupId) {
    for (final c in [...allowedClasses, ?activeClass]) {
      if (c.groupId == groupId && !c.isPlaceholder) return c;
    }
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

  /// The name of the status the record holds, as the Presence module gives
  /// it with the record (#126): the `name` of the record's `code`, trimmed,
  /// such as "Aanwezig", "Doktersattest" or, for an alias, "Te laat zonder
  /// geldige reden". `null` when the record carries no `code`, or one
  /// without a name (and for a half-day built by hand).
  ///
  /// This names the half-days of a grouping class, which has no structure
  /// to ask `PresenceService.getAllCodes` for: its records carry their codes
  /// as those of any class. The module's own web client shows a record's
  /// status from this `code` (its glyph and name).
  ///
  /// Seen live (read-only, 2026-10-05): `getClass` gave a `code` with every
  /// half-day record, in grouping classes and official classes, over a
  /// month of two classes and one school day of all seventeen grouping
  /// classes. For a code, it is the code with the fields `getAllCodes` gives
  /// it for the school's structure (`codeID`, `code`, `name`, `structID`,
  /// ...) and `isAlias` `false`; for an alias, the alias (`aliasID`,
  /// `parentCodeID`, `name`, `isAlias` `true`, its `codeID` set to the
  /// `aliasID`). Its name was the
  /// name `PresenceService.statusNameOf` gives the half-day from the codes
  /// of the structure each time. A record the module answers a save with
  /// (`PresenceSavedHalfDay`) gets it when the answer carries the `code`
  /// too, which was not captured live.
  final String? statusName;

  const PresenceHalfDay({
    required this.presenceId,
    required this.presenceDate,
    required this.part,
    required this.codeId,
    required this.aliasId,
    required this.motivation,
    this.statusName,
  });

  @override
  String toString() =>
      'PresenceHalfDay(part: ${part.wire}, presenceId: $presenceId, '
      'codeId: $codeId, aliasId: $aliasId)';
}

/// A half-day as `PresenceService.setLate` or `setPresent` saved it (#105):
/// the record the Presence module answered the save with, and [before], the
/// half-day as the call read it right before the save.
///
/// The fields of [PresenceHalfDay] are the module's: [presenceId] is the
/// record's ID (a new one when the half-day had no record yet), and
/// [codeId] / [aliasId] are what it stores, so `codeId` is `null` for an
/// alias (such as "Te laat zonder geldige reden"). Name the status with
/// `PresenceService.statusNameOf`.
class PresenceSavedHalfDay extends PresenceHalfDay {
  const PresenceSavedHalfDay({
    required super.presenceId,
    required super.presenceDate,
    required super.part,
    required super.codeId,
    required super.aliasId,
    required super.motivation,
    super.statusName,
    this.before,
  });

  /// The half-day [stored], as the save answer gives it, with [before].
  PresenceSavedHalfDay.of(PresenceHalfDay stored, {PresenceHalfDay? before})
    : this(
        presenceId: stored.presenceId,
        presenceDate: stored.presenceDate,
        part: stored.part,
        codeId: stored.codeId,
        aliasId: stored.aliasId,
        motivation: stored.motivation,
        statusName: stored.statusName,
        before: before,
      );

  /// The half-day as the call read it right before the save (the one an
  /// `onlyReplacing` check looked at), or `null` when the pupil had no
  /// record for it yet.
  final PresenceHalfDay? before;

  @override
  String toString() =>
      'PresenceSavedHalfDay(part: ${part.wire}, presenceId: $presenceId, '
      'codeId: $codeId, aliasId: $aliasId, before: $before)';
}

/// An error of a save that the Presence module refused (#109): one entry of
/// the `errors` of its answer to `Presence/Class/savePupilsPresences`, as
/// `SmartschoolPresenceError.saveErrors` holds it.
///
/// The module gives each error as an object, which its web client reads
/// (its Presence JavaScript, read-only) for its error dialog: `message`, the
/// reason, which it shows once at the top, and `presence`, the record that
/// was not saved, which it lists per line by its `presenceDate`,
/// `partOfDay` and `pupil` (the pupil's name), and finds the pupil's record
/// by its `studentID`. The fields here are those, typed. What the module
/// answers a refused save with was not captured live: no save was sent to
/// the live module for this.
///
/// [toString] shows the [message] and the record's day, half of the day and
/// [userId], not the pupil's name: [pupilName] is personal data, kept out of
/// the error's text and so out of logs.
class PresenceSaveError {
  /// The text an error without a reason of its own gets as its [message]: an
  /// error object without a `message`, or with an empty one.
  static const noReason =
      'The Presence module refused the save without a reason.';

  /// The module's reason (the error's `message`, trimmed), as its web client
  /// shows it (in Dutch); [noReason] when it gave none. For an error that
  /// is not an object, a text that says what it is, without its content.
  final String message;

  /// The internal `userID` of the pupil whose record was not saved (the
  /// record's `studentID`), or `null` when the error does not name one.
  final int? userId;

  /// The day of the record that was not saved (`yyyy-MM-dd`, its
  /// `presenceDate`), or `null` when the error does not name one.
  final String? date;

  /// The half of the day of the record that was not saved (its
  /// `partOfDay`), or `null` when the error names none, or a per-lesson
  /// record (`"none"`).
  final DayPart? part;

  /// The pupil's name as the module gives it with the record (its `pupil`,
  /// such as "Peeters, Lotte"), or `null` when it gives none.
  ///
  /// Personal data: it is in neither [toString] nor the message of the
  /// `SmartschoolPresenceError` that holds this error.
  final String? pupilName;

  const PresenceSaveError({
    required this.message,
    this.userId,
    this.date,
    this.part,
    this.pupilName,
  });

  @override
  String toString() {
    final record = [
      if (date != null) date,
      if (part != null) part!.name,
      if (userId != null) 'userID $userId',
    ];
    return record.isEmpty
        ? 'PresenceSaveError: $message'
        : 'PresenceSaveError: $message (${record.join(', ')})';
  }
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

  /// The `groupID` of the pupil's official class, as the Presence module
  /// gives it with the pupil (its `officialClass`), or `null` when it gives
  /// none (#126).
  ///
  /// For a pupil of a grouping class, which has no structure
  /// ([PresenceClassRef.structId] `null`), this is the class whose structure
  /// names the pupil's half-days: `PresenceConfig.classForGroup` gives its
  /// `structId`, for `PresenceService.getAllCodes`. Seen live (read-only,
  /// 2026-10-05): every pupil of all seventeen grouping classes of the
  /// school had one, an official class that `getConfig` listed with the
  /// school's structure (to an account with the absence-administrator
  /// rights; one without them is listed fewer classes, #121, so it may not
  /// list the pupil's official class). In an official class, it was that
  /// class. A pupil who had moved from 2C ECO to 2E ECO in September, listed
  /// in the grouping class 2C on a day in October, had 2E ECO, the class it
  /// was in on that day.
  final int? officialClassId;

  const PresencePupil({
    required this.userId,
    required this.movementId,
    required this.name,
    this.halfDays = const [],
    this.officialClassId,
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

/// The pupils of a class for one day, as `PresenceService.getClassPupils`
/// returns them, with what the Presence module said about the class on that
/// day (#104).
///
/// It is the list of [PresencePupil]s, so code that takes it as a
/// `List<PresencePupil>` needs no change. An empty list no longer stands for
/// "no pupils" alone: when the module lists no pupils, it answers with
/// [saveIsAllowed] `false` and says why in [errorMessage], as its web client
/// shows it (in Dutch). Seen live (read-only, 2026-10-03), the module
/// answers `Presence/Class/getClass`:
///
/// - for a class with pupils, on a day up to today (a Saturday or a day of
///   the previous school year too): the pupils, [saveIsAllowed] `true` and
///   no [errorMessage];
/// - for a day after today, to an account without the right to set the
///   class's half-days ([PresenceClassRef.userCanConfirm] `false`): no
///   pupils, `false`, "Het is niet mogelijk om in de toekomst afwezigheden
///   op te nemen.". To an account with that right (an absence
///   administrator's, seen 2026-10-04, #123), a day after today in the
///   school year is answered as a day up to today: the pupils, `true`, no
///   reason (seen up to some seventeen weeks ahead); a day of the next
///   school year got no pupils, `false`, "Deze klas bevat geen leerlingen.";
/// - for a class without pupils: no pupils, `false`, "Deze klas bevat geen
///   leerlingen.";
/// - for a class ID it does not know: the same, but without a class:
///   [classRef] is `null`;
/// - for the class `-2` ("Uit Planner", the placeholder the config gives as
///   its active class for a teacher who has no lesson at that moment,
///   [PresenceConfig.activePlaceholder], #117): no pupils, `false`, "U geeft
///   momenteel geen les. Kies een andere klas in de keuzelijst.", and no
///   class.
///
/// No answer with an empty list and [saveIsAllowed] `true` was seen.
class PresenceClassPupils extends ListBase<PresencePupil> {
  /// The [pupils] (copied into a list of its own) and what the module said
  /// about the class.
  PresenceClassPupils(
    Iterable<PresencePupil> pupils, {
    this.classRef,
    this.saveIsAllowed,
    this.errorMessage,
  }) : _pupils = List.of(pupils);

  final List<PresencePupil> _pupils;

  /// The class as the module names it in its answer (its `groupID`, `name`,
  /// `structID`, `userCanRecord`, ...), or `null` when the answer names no
  /// class: the module does not know the class ID (or the list was not read
  /// from an answer).
  final PresenceClassRef? classRef;

  /// Whether the module would save presences for the class on that day (its
  /// `saveIsAllowed`), or `null` when the answer does not say (or the list
  /// was not read from an answer).
  ///
  /// `false` with an empty list: the module did not list the class on that
  /// day, for the reason in [errorMessage].
  final bool? saveIsAllowed;

  /// The module's reason for not listing the class on that day (its
  /// `errorMessage`, such as "Deze klas bevat geen leerlingen."), as it
  /// shows it to the user, or `null` when it gave none (it answers `""` for
  /// a class it lists).
  final String? errorMessage;

  @override
  int get length => _pupils.length;

  @override
  set length(int newLength) => _pupils.length = newLength;

  @override
  PresencePupil operator [](int index) => _pupils[index];

  @override
  void operator []=(int index, PresencePupil value) => _pupils[index] = value;

  @override
  void add(PresencePupil element) => _pupils.add(element);

  @override
  void addAll(Iterable<PresencePupil> iterable) => _pupils.addAll(iterable);
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

/// Parses [value] leniently to a list of `int`s, skipping the entries that
/// [_asInt] cannot read; empty when [value] is not a list.
List<int> _asIntList(dynamic value) {
  if (value is! List) return const [];
  return List.unmodifiable([for (final entry in value) ?_asInt(entry)]);
}
