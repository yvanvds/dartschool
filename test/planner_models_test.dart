// Tests for issue #84: the calendars of the planner (`PlannerCalendar`) and
// the types of its elements (`PlannedElementType`). The parsing of elements
// and the requests are tested in planner_service_test.dart.
//
// The calendar IDs follow the forms seen on the live site (2026-10-02):
// `{platformId}_{userId}_{coaccount}` for a user, `{platformId}_{groupId}`
// for a class, `{platformId}_{itemId}` for a location (its bare item ID gave
// 400). The IDs below are fakes.
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';

void main() {
  forbidRealNetwork();

  group('PlannerCalendar', () {
    test('a user calendar takes the whole user ID, co-account included', () {
      final own = PlannerCalendar.user('4069_1001_0');
      expect(own.type, PlannerCalendarType.user);
      expect(own.id, '4069_1001_0');
      expect(PlannerCalendar.user('4069_1001_2').id, '4069_1001_2');
    });

    test('a user calendar refuses the bare user ID of SmartschoolUser.id', () {
      for (final id in ['1001', '4069_1001', '4069_1001_0_1', '', ' ']) {
        expect(
          () => PlannerCalendar.user(id),
          throwsA(isA<ArgumentError>()),
          reason: id,
        );
      }
    });

    test('a group calendar takes {platformId}_{groupId}', () {
      final klas = PlannerCalendar.group('4069_2001');
      expect(klas.type, PlannerCalendarType.group);
      expect(klas.id, '4069_2001');
    });

    test('a location calendar takes {platformId}_{itemId}, not the bare item '
        'ID that the planner answers with 400', () {
      const item = '10000000-0000-4000-8000-000000000101';
      final room = PlannerCalendar.location('4069_$item');
      expect(room.type, PlannerCalendarType.location);
      expect(room.id, '4069_$item');
      expect(
        () => PlannerCalendar.location(item),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('IDs without a platform prefix, or with characters that would '
        'change the URL, are refused', () {
      for (final id in [
        '2001',
        '_2001',
        'x_2001',
        '4069_',
        '4069_20/01',
        '4069_2001?x=1',
        '4069_20 01',
      ]) {
        expect(
          () => PlannerCalendar.group(id),
          throwsA(isA<ArgumentError>()),
          reason: id,
        );
        expect(
          () => PlannerCalendar.location(id),
          throwsA(isA<ArgumentError>()),
          reason: id,
        );
      }
    });

    test('the unnamed constructor checks the ID as the named ones do', () {
      expect(
        PlannerCalendar(PlannerCalendarType.user, '4069_1001_0'),
        PlannerCalendar.user('4069_1001_0'),
      );
      expect(
        PlannerCalendar(PlannerCalendarType.group, '4069_2001'),
        PlannerCalendar.group('4069_2001'),
      );
      expect(
        PlannerCalendar(PlannerCalendarType.location, '4069_abc'),
        PlannerCalendar.location('4069_abc'),
      );
      expect(
        () => PlannerCalendar(PlannerCalendarType.user, '4069_2001'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('calendars are equal by type and ID', () {
      expect(
        PlannerCalendar.group('4069_2001'),
        PlannerCalendar.group('4069_2001'),
      );
      expect(
        PlannerCalendar.group('4069_2001').hashCode,
        PlannerCalendar.group('4069_2001').hashCode,
      );
      expect(
        PlannerCalendar.group('4069_2001'),
        isNot(PlannerCalendar.location('4069_2001')),
      );
      expect(
        PlannerCalendar.group('4069_2001').toString(),
        'PlannerCalendar(group: 4069_2001)',
      );
    });

    test('the calendar types carry the names of the planner URL', () {
      expect(PlannerCalendarType.values.map((t) => t.wireName), [
        'user',
        'group',
        'location',
      ]);
    });
  });

  group('PlannedElementType', () {
    test('knows the element types of the planner web client', () {
      expect(
        [
          for (final type in PlannedElementType.values)
            if (type != PlannedElementType.other) type.wireName,
        ],
        [
          'planned-lessons',
          'planned-assignments',
          'planned-placeholders',
          'planned-to-dos',
          'planned-school-activities',
          'planned-meetings',
          'planned-lesson-free-days',
          'planned-generics',
          'planned-activities',
          'planned-routines',
          'planned-partner-elements',
          'planned-lesson-clusters',
          'planned-lesson-cluster-moments',
          'planned-lesson-cluster-lessons',
          'planned-lesson-cluster-assignments',
          'planned-merged-teaching-moments',
        ],
      );
    });

    test('fromWire maps every known name back to its type', () {
      for (final type in PlannedElementType.values) {
        if (type == PlannedElementType.other) continue;
        expect(PlannedElementType.fromWire(type.wireName!), type);
      }
      expect(
        PlannedElementType.fromWire('planned-lessons'),
        PlannedElementType.lesson,
      );
      expect(
        PlannedElementType.fromWire('planned-placeholders'),
        PlannedElementType.placeholder,
      );
    });

    test('an unknown name is other, which has no planner name', () {
      expect(
        PlannedElementType.fromWire('planned-excursions'),
        PlannedElementType.other,
      );
      expect(PlannedElementType.fromWire(''), PlannedElementType.other);
      expect(PlannedElementType.other.wireName, isNull);
    });
  });

  group('the calendar of what an element names', () {
    test('a user, a group and a location give their planner', () {
      const user = PlannerUser(id: '4069_1002_0', name: 'Piet Peeters');
      const klas = PlannerGroup(id: '4069_2001', platformId: 4069, name: '6A1');
      const room = PlannerLocation(
        id: '10000000-0000-4000-8000-000000000101',
        platformId: 4069,
        title: '101',
      );
      expect(user.calendar, PlannerCalendar.user('4069_1002_0'));
      expect(klas.calendar, PlannerCalendar.group('4069_2001'));
      expect(
        room.calendar,
        PlannerCalendar.location('4069_10000000-0000-4000-8000-000000000101'),
      );
    });
  });
}
