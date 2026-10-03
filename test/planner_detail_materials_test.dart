// Tests for issue #98: the labels, attachments and weblinks of a planned
// element's detail (`PlannedElementDetail.labels`, `.attachments`,
// `.weblinks`), which were only in `raw`.
//
// The answers below are trimmed captures of the live planner API, read from
// the developer's own planner (read-only, 2026-10-03):
//   - GET /planner/api/v1/planned-assignments/{platformId}/{id}
//       (an own assignment with an attachment and a weblink, no labels)
//   - GET /planner/api/v1/planned-lessons/{platformId}/{id}
//       (an own lesson with two school labels, an own label and a weblink,
//       no attachments)
//   - GET /planner/api/v1/planned-placeholders/{platformId}/{id}
//       (a timetable slot: `labels` empty, no `attachments` or `weblinks`)
// with every name, picture, user, group, course, location, label, element,
// attachment and weblink ID, every title, file name, weblink name and URL
// replaced by obvious fakes ("Jan Janssens" is the authenticated user
// `4069_1001_0`, "Springfield Academy"; `JAAR 6` and `TRIMESTER 1` are the
// school's labels as they are). The capabilities are trimmed to the flags
// that matter. Only the visibility option `always` was seen live: the other
// options, and the answers in other shapes, are made up from the web
// client's model (`{fileName, fileSize, ..., visibility: {option:
// always|never|at-start|at-end|days-after-end, daysAfterEnd}}`).
//
// Everything here reads: the fake Smartschool fails the test on any request
// that is not a GET of a scripted path.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

class _Credentials extends Credentials {
  @override
  String get username => 'user';
  @override
  String get password => 'pass';
  @override
  String get mainUrl => _host;
  @override
  String? get mfa => 'JBSWY3DPEHPK3PXP';
}

const _api = '/planner/api/v1';

const _assignmentId = 'e0000000-0000-4000-8000-000000000021';
const _lessonId = 'e0000000-0000-4000-8000-000000000022';
const _slotId = 'e0000000-0000-5000-8000-000000000023';
const _attachmentId = 'f0000000-0000-4000-8000-000000000031';
const _assignmentWeblinkId = 'f0000000-0000-4000-8000-000000000041';
const _lessonWeblinkId = 'f0000000-0000-4000-8000-000000000042';
const _jaar6 = '4069_d0000000-0000-4000-8000-000000000001';
const _trimester1 = '4069_d0000000-0000-4000-8000-000000000002';
const _ownLabel = '4069_1001_0_d0000000-0000-4000-8000-000000000003';

const _assignmentPath = '$_api/planned-assignments/4069/$_assignmentId';
const _lessonPath = '$_api/planned-lessons/4069/$_lessonId';
const _slotPath = '$_api/planned-placeholders/4069/$_slotId';

/// An own assignment with an attachment (a Word file) and a weblink, both
/// visible to pupils always, and no labels.
const _assignment = r'''
{"id":"e0000000-0000-4000-8000-000000000021","platformId":4069,"name":"Overhoring hoofdstuk 2","icon":"flags_red_yellow","assignmentType":{"id":"a0000000-0000-4000-8000-000000000002","name":"Grote Overhoring","abbreviation":"GO","isVisible":true,"defaultTiming":"deadline","weight":0},"info":"","privateInfo":"","publicInfo":"<p>De beoordelingsrubriek en oefenvragen vind je bij deze opdracht.<\/p>","period":{"dateTimeFrom":"2026-03-26T10:20:00+01:00","dateTimeTo":"2026-03-26T11:10:00+01:00","wholeDay":false,"deadline":true},"organisers":{"users":[{"id":"4069_1001_0","pictureHash":"initials_JJ","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_JJ\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Jan Janssens","startingWithLastName":"Janssens Jan"},"sort":"janssens-jan","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2002","id":"4069_2002","platformId":4069,"name":"6A2","type":"K","icon":"briefcase","sort":"6A2"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"miniDBItems":[],"labels":[],"uploadFolder":null,"attachments":[{"id":"f0000000-0000-4000-8000-000000000031","fileName":"rubriek.docx","fileSize":8947,"mimeType":"application\/vnd.openxmlformats-officedocument.wordprocessingml.document","visibility":{"option":"always","daysAfterEnd":null}}],"courses":[{"id":"c0000000-0000-4000-8000-000000000003","platformId":4069,"name":"Nederlands","scheduleCodes":["NEDER","NEDER1"],"icon":"schoolbord","courseCluster":{"id":3,"name":"Nederlands"},"isVisible":true}],"courseLinks":[],"locations":[{"id":"10000000-0000-4000-8000-000000000102","platformId":4069,"platformName":"Springfield Academy","number":"","title":"102","icon":"","type":"mini-db-item","selectable":true}],"goals":[],"weblinks":[{"id":"f0000000-0000-4000-8000-000000000041","name":"Oefenvragen","url":"https:\/\/example.com\/oefenvragen?hoofdstuk=2","icon":"earth","visibility":{"option":"always","daysAfterEnd":null}}],"partnerWeblinks":[],"deeplinks":[],"reservations":[],"isParticipant":false,"albums":[],"capabilities":{"canUserEdit":true,"canUserTrash":true,"canUserChangeLabels":true,"canUserAddAttachments":true,"canUserRemoveAttachment":true,"canUserEditVisibilityOfAttachment":true,"canUserAddWeblink":true,"canUserChangeWeblink":true,"canUserRemoveWeblink":true,"canUserEditVisibilityOfWeblink":true,"canUserSeeProperties":{"id":true,"name":true,"labels":true,"attachments":true,"weblinks":true,"partnerWeblinks":true}},"resolvedStatus":"unresolved","presenceSaved":false,"showPresenceChoices":true,"onlineSession":null,"plannedElementType":"planned-assignments","plannedToDos":[],"isAnnounced":false,"visibility":{"afterDate":"2026-03-20T15:52:00+01:00"},"canUserAccessEvaluations":true,"hasLinkedEvaluation":false,"linkedEvaluation":null,"sort":"20260326102000_5_6A1_Overhoring hoofdstuk 2","unconfirmed":false,"pinned":false,"color":"aqua-200","dateCreated":"2026-03-20T15:52:38+01:00","reminders":[],"participantsChangedAfterEvaluation":false,"joinIds":{"from":"f0000000-0000-5000-8000-000000000051","to":"f0000000-0000-5000-8000-000000000051"}}
''';

/// An own lesson with two school labels and an own label (in the planner's
/// order: a school label, the own label, a school label), a weblink, and no
/// attachments.
const _lesson = r'''
{"id":"e0000000-0000-4000-8000-000000000022","platformId":4069,"name":"Grafieken lezen","icon":"document_observation","info":"","privateInfo":"","publicInfo":"<p>Werk verder aan de cursus.<\/p>","period":{"dateTimeFrom":"2025-09-23T08:30:00+02:00","dateTimeTo":"2025-09-23T09:20:00+02:00","wholeDay":false,"deadline":false},"organisers":{"users":[{"id":"4069_1001_0","pictureHash":"initials_JJ","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_JJ\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Jan Janssens","startingWithLastName":"Janssens Jan"},"sort":"janssens-jan","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"miniDBItems":[],"labels":[{"identifier":"4069_d0000000-0000-4000-8000-000000000001","type":"platform","text":"JAAR 6","color":"aqua","isVisible":true,"id":"4069_d0000000-0000-4000-8000-000000000001","platformId":4069,"ssId":4069,"locations":["planner_routines","planner_activities","navigator","lesson_content","planner"]},{"identifier":"4069_1001_0_d0000000-0000-4000-8000-000000000003","type":"user","text":"Lussen","color":"steel","isVisible":true,"id":"4069_1001_0_d0000000-0000-4000-8000-000000000003","userId":"4069_1001_0"},{"identifier":"4069_d0000000-0000-4000-8000-000000000002","type":"platform","text":"TRIMESTER 1","color":"yellow","isVisible":true,"id":"4069_d0000000-0000-4000-8000-000000000002","platformId":4069,"ssId":4069,"locations":["planner_routines","planner_activities","navigator","lesson_content","planner"]}],"attachments":[],"courses":[{"id":"c0000000-0000-4000-8000-000000000005","platformId":4069,"name":"informatica","scheduleCodes":["INFO"],"icon":"schoolbord","courseCluster":{"id":4,"name":"Informatica"},"isVisible":true}],"courseLinks":[],"locations":[{"id":"10000000-0000-4000-8000-000000000101","platformId":4069,"platformName":"Springfield Academy","number":"","title":"101","icon":"","type":"mini-db-item","selectable":true}],"goals":[],"weblinks":[{"id":"f0000000-0000-4000-8000-000000000042","name":"Oefenreeks grafieken","url":"https:\/\/example.com\/grafieken","icon":"chart_column_color","visibility":{"option":"always","daysAfterEnd":null}}],"partnerWeblinks":[],"deeplinks":[],"reservations":[],"isParticipant":false,"albums":[],"capabilities":{"canUserEdit":true,"canUserChangeLabels":true,"canUserAddAttachments":true,"canUserAddWeblink":true,"canUserSeeProperties":{"id":true,"name":true,"labels":true,"attachments":true,"weblinks":true,"partnerWeblinks":true}},"presenceSaved":false,"showPresenceChoices":true,"onlineSession":null,"plannedElementType":"planned-lessons","plannedToDos":[],"sort":"20250923083000_4_6A1_Grafieken lezen","unconfirmed":false,"pinned":false,"color":"aqua-200","reminders":[],"joinIds":{"from":"f0000000-0000-5000-8000-000000000052","to":"f0000000-0000-5000-8000-000000000053"}}
''';

/// A timetable slot of the own planner: `labels` empty, and no
/// `attachments` or `weblinks` at all (its `canUserSeeProperties` does not
/// list them).
const _slot = r'''
{"id":"e0000000-0000-5000-8000-000000000023","platformId":4069,"period":{"dateTimeFrom":"2026-11-20T11:10:00+01:00","dateTimeTo":"2026-11-20T12:00:00+01:00","wholeDay":false,"deadline":false},"organisers":{"users":[{"id":"4069_1001_0","pictureHash":"initials_JJ","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_JJ\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Jan Janssens","startingWithLastName":"Janssens Jan"},"sort":"janssens-jan","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"labels":[],"presenceSaved":false,"showPresenceChoices":false,"courses":[{"id":"c0000000-0000-4000-8000-000000000005","platformId":4069,"name":"informatica","scheduleCodes":["INFO"],"icon":"schoolbord","courseCluster":{"id":4,"name":"Informatica"},"isVisible":true}],"courseLinks":[],"locations":[{"id":"10000000-0000-4000-8000-000000000101","platformId":4069,"platformName":"Springfield Academy","number":"","title":"101","icon":"","type":"mini-db-item","selectable":true}],"isParticipant":false,"capabilities":{"canUserEdit":true,"canUserReplace":true,"canUserSeeProperties":{"id":true,"period":true,"labels":true,"courses":true,"locations":true}},"plannedElementType":"planned-placeholders","onlineSession":null,"reservations":[],"sort":"20261120111000_8_6A1_","unconfirmed":false,"pinned":false,"color":"aqua-200","reminders":[],"joinIds":{"from":"f0000000-0000-5000-8000-000000000054","to":"f0000000-0000-5000-8000-000000000055"}}
''';

/// [answer] (a captured detail) with [change] applied to its decoded JSON.
String _with(String answer, void Function(Map<String, dynamic> json) change) {
  final json = jsonDecode(answer) as Map<String, dynamic>;
  change(json);
  return jsonEncode(json);
}

/// A Smartschool that answers the GETs of [answers] (by path) with `200`,
/// and fails the test on any other request.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(this.answers);

  final Map<String, String> answers;

  /// Every request that reached it, as `METHOD path`.
  final List<String> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add('${options.method} ${uri.path}');
    expect(options.method, 'GET', reason: 'reading a detail only reads');
    final body = answers[uri.path];
    if (body == null) fail('Unexpected request: ${options.method} $uri');
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A [SmartschoolPlannerError], not an authentication failure.
Matcher _plannerError([Object? message = anything]) => allOf(
  isNot(isA<SmartschoolAuthenticationError>()),
  isA<SmartschoolPlannerError>().having((e) => e.message, 'message', message),
);

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, PlannerService)> serve(
    Map<String, String> answers,
  ) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    final server = _Smartschool(answers);
    client.dio.httpClientAdapter = server;
    return (server, PlannerService(client));
  }

  /// The detail of the assignment, as [getPlannedElement] reads it, with
  /// [answer] as the planner's answer.
  Future<PlannedElementDetail> readAssignment([
    String answer = _assignment,
  ]) async {
    final (server, planner) = await serve({_assignmentPath: answer});
    final detail = await planner.getPlannedElement(
      type: PlannedElementType.assignment,
      platformId: 4069,
      id: _assignmentId,
    );
    expect(server.requests, ['GET $_assignmentPath']);
    return detail;
  }

  group('PlannedElementDetail.attachments', () {
    test('an attachment has its ID, file name, size, MIME type and '
        'visibility, as seen live', () async {
      final assignment = await readAssignment();

      final file = assignment.attachments!.single;
      expect(file, isA<PlannerAttachment>());
      expect(file.id, _attachmentId);
      expect(file.name, 'rubriek.docx');
      expect(file.size, 8947);
      expect(
        file.mimeType,
        'application/vnd.openxmlformats-officedocument.wordprocessingml'
        '.document',
      );
      expect(file.visibility!.option, PlannerVisibilityOption.always);
      expect(file.visibility!.optionName, 'always');
      expect(file.visibility!.daysAfterEnd, isNull);
      expect(file.toString(), contains('rubriek.docx'));
    });

    test('an element without attachments has an empty list', () async {
      final (_, planner) = await serve({_lessonPath: _lesson});

      final lesson = await planner.getPlannedElement(
        type: PlannedElementType.lesson,
        platformId: 4069,
        id: _lessonId,
      );

      expect(lesson.attachments, isNotNull);
      expect(lesson.attachments, isEmpty);
    });

    test('a size given as a text is read as a number; a missing size, MIME '
        'type or visibility is null, a missing file name ""', () async {
      final assignment = await readAssignment(
        _with(_assignment, (json) {
          json['attachments'] = [
            {
              'id': 'f0000000-0000-4000-8000-000000000032',
              'fileName': 'oefeningen.pdf',
              'fileSize': '120034',
            },
            {'id': 'f0000000-0000-4000-8000-000000000033'},
          ];
        }),
      );

      final [pdf, bare] = assignment.attachments!;
      expect(pdf.name, 'oefeningen.pdf');
      expect(pdf.size, 120034);
      expect(pdf.mimeType, isNull);
      expect(pdf.visibility, isNull);
      expect(bare.id, 'f0000000-0000-4000-8000-000000000033');
      expect(bare.name, '');
      expect(bare.size, isNull);
    });
  });

  group('PlannedElementDetail.weblinks', () {
    test('a weblink has its ID, name, URL, icon and visibility, as seen '
        'live', () async {
      final assignment = await readAssignment();

      final link = assignment.weblinks!.single;
      expect(link, isA<PlannerWeblink>());
      expect(link.id, _assignmentWeblinkId);
      expect(link.name, 'Oefenvragen');
      expect(link.url, 'https://example.com/oefenvragen?hoofdstuk=2');
      expect(link.icon, 'earth');
      expect(link.visibility!.option, PlannerVisibilityOption.always);
      expect(link.toString(), contains('Oefenvragen'));
    });

    test('a lesson\'s weblink', () async {
      final (_, planner) = await serve({_lessonPath: _lesson});

      final lesson = await planner.getPlannedElement(
        type: PlannedElementType.lesson,
        platformId: 4069,
        id: _lessonId,
      );

      final link = lesson.weblinks!.single;
      expect(link.id, _lessonWeblinkId);
      expect(link.name, 'Oefenreeks grafieken');
      expect(link.url, 'https://example.com/grafieken');
      expect(link.icon, 'chart_column_color');
    });

    test('the visibility options of the web client, and one the library '
        'does not know', () async {
      Map<String, Object?> link(String id, Object? visibility) => {
        'id': id,
        'name': 'Link $id',
        'url': 'https://example.com/$id',
        'icon': 'earth',
        'visibility': visibility,
      };
      final assignment = await readAssignment(
        _with(_assignment, (json) {
          json['weblinks'] = [
            link('1', {'option': 'never', 'daysAfterEnd': null}),
            link('2', {'option': 'at-start', 'daysAfterEnd': null}),
            link('3', {'option': 'at-end', 'daysAfterEnd': null}),
            link('4', {'option': 'days-after-end', 'daysAfterEnd': 2}),
            link('5', {'option': 'after-the-exams', 'daysAfterEnd': null}),
            link('6', {'daysAfterEnd': null}),
            link('7', null),
          ];
        }),
      );

      final visibilities = [
        for (final link in assignment.weblinks!) link.visibility,
      ];
      expect(visibilities.map((v) => v?.option), [
        PlannerVisibilityOption.never,
        PlannerVisibilityOption.atStart,
        PlannerVisibilityOption.atEnd,
        PlannerVisibilityOption.daysAfterEnd,
        PlannerVisibilityOption.other,
        PlannerVisibilityOption.other,
        null,
      ]);
      expect(visibilities[3]!.daysAfterEnd, 2);
      expect(visibilities[4]!.optionName, 'after-the-exams');
      expect(visibilities[5]!.optionName, '');
      expect(PlannerVisibilityOption.daysAfterEnd.wireName, 'days-after-end');
      expect(PlannerVisibilityOption.other.wireName, isNull);
    });
  });

  group('PlannedElementDetail.labels', () {
    test('school labels and an own label, with their text, colour and '
        'type, in the planner\'s order', () async {
      final (_, planner) = await serve({_lessonPath: _lesson});

      final lesson = await planner.getPlannedElement(
        type: PlannedElementType.lesson,
        platformId: 4069,
        id: _lessonId,
      );

      final labels = lesson.labels!;
      expect(labels, everyElement(isA<PlannerLabel>()));
      expect(labels.map((l) => '${l.text}/${l.color}/${l.type}'), [
        'JAAR 6/aqua/platform',
        'Lussen/steel/user',
        'TRIMESTER 1/yellow/platform',
      ]);
      expect(labels.map((l) => l.id), [_jaar6, _ownLabel, _trimester1]);
      expect(labels.map((l) => l.isSchoolLabel), [true, false, true]);
      expect(labels.every((l) => l.isVisible), isTrue);
      expect(labels.first.toString(), contains('JAAR 6'));
    });

    test('an element without labels has an empty list', () async {
      final assignment = await readAssignment();

      expect(assignment.labels, isNotNull);
      expect(assignment.labels, isEmpty);
    });

    test('a hidden label, and one without colour or type', () async {
      final assignment = await readAssignment(
        _with(_assignment, (json) {
          json['labels'] = [
            {
              'id': _jaar6,
              'type': 'platform',
              'text': ' JAAR 6 ',
              'color': 'aqua',
              'isVisible': false,
            },
            {'id': _ownLabel, 'text': 'Lussen'},
          ];
        }),
      );

      final [hidden, bare] = assignment.labels!;
      expect(hidden.text, 'JAAR 6');
      expect(hidden.isVisible, isFalse);
      expect(bare.color, isNull);
      expect(bare.type, '');
      expect(bare.isSchoolLabel, isFalse);
      expect(bare.isVisible, isTrue);
    });
  });

  group('a list the planner does not give', () {
    test('a timetable slot has empty labels, and no attachments or weblinks '
        '(null), as seen live', () async {
      final (_, planner) = await serve({_slotPath: _slot});

      final slot = await planner.getPlannedElement(
        type: PlannedElementType.placeholder,
        platformId: 4069,
        id: _slotId,
      );

      expect(slot.labels, isEmpty);
      expect(slot.attachments, isNull);
      expect(slot.weblinks, isNull);
    });

    test('a list given as null is null too', () async {
      final assignment = await readAssignment(
        _with(_assignment, (json) {
          json['labels'] = null;
          json['attachments'] = null;
          json['weblinks'] = null;
        }),
      );

      expect(assignment.labels, isNull);
      expect(assignment.attachments, isNull);
      expect(assignment.weblinks, isNull);
    });

    test('getDetail of a listed element gives the same lists', () async {
      final (server, planner) = await serve({_assignmentPath: _assignment});
      final listed = PlannedElement.fromJson(
        jsonDecode(_assignment) as Map<String, dynamic>,
      );

      final detail = await planner.getDetail(listed);

      expect(detail.attachments!.single.name, 'rubriek.docx');
      expect(detail.weblinks!.single.name, 'Oefenvragen');
      expect(detail.labels, isEmpty);
      expect(server.requests, ['GET $_assignmentPath']);
    });
  });

  group('lists in an unknown shape are refused', () {
    Future<void> expectRefused(
      void Function(Map<String, dynamic> json) change,
      Object? message,
    ) async {
      final (_, planner) = await serve({
        _assignmentPath: _with(_assignment, change),
      });
      await expectLater(
        planner.getPlannedElement(
          type: PlannedElementType.assignment,
          platformId: 4069,
          id: _assignmentId,
        ),
        throwsA(_plannerError(message)),
      );
    }

    test('a list that is not a list', () async {
      await expectRefused(
        (json) => json['attachments'] = {'id': _attachmentId},
        contains('the attachments of planned element $_assignmentId'),
      );
      await expectRefused(
        (json) => json['weblinks'] = 'none',
        contains('the weblinks of planned element $_assignmentId'),
      );
      await expectRefused(
        (json) => json['labels'] = 3,
        contains('the labels of planned element $_assignmentId'),
      );
    });

    test('an item that is not an object, or has no ID', () async {
      await expectRefused(
        (json) => json['attachments'] = ['rubriek.docx'],
        contains('one of the attachments of planned element'),
      );
      await expectRefused(
        (json) => json['weblinks'] = [
          {'name': 'Oefenvragen', 'url': 'https://example.com/'},
        ],
        contains('a weblink without its id'),
      );
      await expectRefused(
        (json) => json['labels'] = [
          {'text': 'JAAR 6'},
        ],
        contains('a label without its id'),
      );
    });

    test('a visibility that is not an object', () async {
      await expectRefused(
        (json) => (json['attachments'] as List).single['visibility'] = 'always',
        contains('the visibility of attachment $_attachmentId'),
      );
    });
  });

  test('raw still holds the lists as the planner gave them', () async {
    final assignment = await readAssignment();

    expect(
      (assignment.raw['attachments'] as List).single['fileName'],
      'rubriek.docx',
    );
    expect((assignment.raw['weblinks'] as List).single['url'], isNotEmpty);
    expect(assignment.raw['partnerWeblinks'], isEmpty);
  });
}
