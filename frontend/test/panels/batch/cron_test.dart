import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/panels/batch/cron.dart';

DateTime u(int y, int mo, int d, [int h = 0, int mi = 0]) => DateTime.utc(y, mo, d, h, mi);

void main() {
  group('CronSchedule.tryParse', () {
    test('accepts standard forms', () {
      for (final e in ['* * * * *', '*/5 * * * *', '0 0 1,15 * *', '0 9-17/2 * * MON-FRI', '0 0 * JAN,JUL ?', '5/15 * * * *', '@hourly', '@DAILY', 'CRON_TZ=Europe/London 0 2 * * *', '0 0 * * 7']) {
        expect(CronSchedule.tryParse(e), isNotNull, reason: e);
      }
    });

    test('rejects malformed expressions', () {
      for (final e in ['', '* * * *', '* * * * * *', '60 * * * *', '* 24 * * *', '* * 0 * *', '* * * 13 *', '* * * * 8', '*/0 * * * *', '5-1 * * * *', 'a * * * *', '@every 5m', '@reboot', '1,,2 * * * *']) {
        expect(CronSchedule.tryParse(e), isNull, reason: e);
      }
    });

  });

  group('describeCron', () {
    final cases = {
      '* * * * *': 'every minute',
      '*/5 * * * *': 'every 5 minutes',
      '*/1 * * * *': 'every minute',
      '0 * * * *': 'every hour at minute 0',
      '15 * * * *': 'every hour at minute 15',
      '30 2 * * *': 'at 02:30 every day',
      '0 0 * * *': 'at 00:00 every day',
      '0 9,17 * * *': 'at 09:00 and 17:00 every day',
      '0,30 9 * * *': 'at 09:00 and 09:30 every day',
      '0 */6 * * 1-5': 'at minute 0 past every 6th hour on Mon–Fri',
      '0 */2 * * *': 'at minute 0 past every 2nd hour',
      '*/10 9-17 * * MON-FRI': 'every 10 minutes between 09:00 and 17:59 on Mon–Fri',
      '0,15,30,45 * * * *': 'at minutes 0, 15, 30 and 45',
      '0 9 * * 1,3,5': 'at 09:00 on Mon, Wed and Fri',
      '0 9 * * 0': 'at 09:00 on Sunday',
      '0 9 * * 7': 'at 09:00 on Sunday',
      '0 0 1 * *': 'at 00:00 on day 1 of the month',
      '0 0 1,15 * *': 'at 00:00 on days 1 and 15 of the month',
      '0 0 1-7 * *': 'at 00:00 on days 1–7 of the month',
      '0 0 1 1 *': 'at 00:00 on day 1 of the month in January',
      '0 0 1 */3 *': 'at 00:00 on day 1 of the month in every 3rd month',
      '0 0 * 1-3 *': 'at 00:00 in Jan–Mar',
      '0 0 * JAN,JUL *': 'at 00:00 in Jan and Jul',
      '0 0 13 * 5': 'at 00:00 on day 13 of the month or on Friday',
      '0-29 * * * *': 'every minute from 0 through 29',
      '5/15 * * * *': 'every 15th minute from 5',
      '0 22 * * 1-5': 'at 22:00 on Mon–Fri',
      '0 8 * * 6,0': 'at 08:00 on Sun and Sat',
      '@hourly': 'every hour, on the hour',
      '@daily': 'every day at midnight',
      '@midnight': 'every day at midnight',
      '@weekly': 'every Sunday at midnight',
      '@monthly': 'at midnight on the 1st of every month',
      '@yearly': 'at midnight on 1 January every year',
      '@annually': 'at midnight on 1 January every year',
    };
    cases.forEach((expr, want) {
      test(expr, () => expect(describeCron(expr), want));
    });

    test('returns null when it cannot parse', () {
      expect(describeCron('not a cron'), isNull);
      expect(describeCron('@every 1h'), isNull);
    });
  });

  group('ordinal', () {
    test('suffixes', () {
      expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111].map(ordinal).toList(),
          ['1st', '2nd', '3rd', '4th', '11th', '12th', '13th', '21st', '22nd', '23rd', '101st', '111th']);
    });
  });

  group('nextRuns (UTC)', () {
    List<DateTime> runs(String e, DateTime from, [int n = 5]) => CronSchedule.tryParse(e)!.nextRuns(from, count: n);

    test('day-of-month and day-of-week are ORed when both restricted', () {
      // 13th of the month OR any Friday. Nov 2026: Fridays 6, 13, 20; Dec 13 is a Sunday.
      expect(runs('0 0 13 * 5', u(2026, 11, 1), 5), [u(2026, 11, 6), u(2026, 11, 13), u(2026, 11, 20), u(2026, 11, 27), u(2026, 12, 4)]);
    });

    test('impossible dates yield nothing', () {
      expect(runs('0 0 30 2 *', u(2026, 1, 1)), isEmpty);
    });

  });

  group('PosixTz', () {
    test('parses fixed and DST rules', () {
      final ist = PosixTz.tryParse('IST-5:30')!;
      expect(ist.offsetAt(u(2026, 6, 1)), const Duration(hours: 5, minutes: 30));
      expect(ist.hasDst, isFalse);
      final sp = PosixTz.tryParse('<-03>3')!;
      expect(sp.offsetAt(u(2026, 6, 1)), const Duration(hours: -3));
      expect(sp.abbreviationAt(u(2026, 6, 1)), '-03');
      expect(PosixTz.tryParse('garbage'), isNull);
      expect(PosixTz.tryParse('EST5EDT,M3.2.0'), isNull);
    });

    test('wallToUtc skips gaps and picks the first of a fold', () {
      final l = PosixTz.tryParse('GMT0BST,M3.5.0/1,M10.5.0')!;
      expect(l.wallToUtc(u(2026, 3, 29, 1, 30)), isNull);
      expect(l.wallToUtc(u(2026, 10, 25, 1, 30)), u(2026, 10, 25, 0, 30));
      expect(l.wallToUtc(u(2026, 7, 1, 12)), u(2026, 7, 1, 11));
    });
  });

  group('resolveZone', () {
    test('UTC, Etc/GMT offsets, built-ins and unknown zones', () {
      final saved = zoneInfoFooter;
      zoneInfoFooter = (_) => null;
      addTearDown(() => zoneInfoFooter = saved);
      expect(resolveZone(null)!.offsetAt(u(2026, 1, 1)), Duration.zero);
      expect(resolveZone('Etc/GMT+5')!.offsetAt(u(2026, 1, 1)), const Duration(hours: -5));
      expect(resolveZone('Etc/GMT-3')!.offsetAt(u(2026, 1, 1)), const Duration(hours: 3));
      expect(resolveZone('Asia/Tokyo')!.offsetAt(u(2026, 1, 1)), const Duration(hours: 9));
      expect(resolveZone('Mars/Olympus_Mons'), isNull);
    });

  });

  group('nextRuns with time zones', () {
    final london = PosixTz.tryParse('GMT0BST,M3.5.0/1,M10.5.0', name: 'Europe/London')!;
    final ny = PosixTz.tryParse('EST5EDT,M3.2.0,M11.1.0', name: 'America/New_York')!;

    test('02:30 London in summer is 01:30 UTC', () {
      final r = CronSchedule.tryParse('30 2 * * *')!.nextRuns(u(2026, 7, 1), count: 2, zone: london);
      expect(r, [u(2026, 7, 1, 1, 30), u(2026, 7, 2, 1, 30)]);
    });

    test('09:00 New York across the November DST change', () {
      final r = CronSchedule.tryParse('0 9 * * *')!.nextRuns(u(2026, 10, 31, 0), count: 3, zone: ny);
      expect(r, [u(2026, 10, 31, 13), u(2026, 11, 1, 14), u(2026, 11, 2, 14)]);
    });

    test('runs inside the spring-forward gap are skipped', () {
      final r = CronSchedule.tryParse('30 1 * * *')!.nextRuns(u(2026, 3, 28, 12), count: 2, zone: london);
      expect(r, [u(2026, 3, 30, 0, 30), u(2026, 3, 31, 0, 30)]);
    });

    test('fold runs once at the first occurrence', () {
      final r = CronSchedule.tryParse('30 1 * * *')!.nextRuns(u(2026, 10, 24, 12), count: 2, zone: london);
      expect(r, [u(2026, 10, 25, 0, 30), u(2026, 10, 26, 1, 30)]);
    });

    test('day boundary uses the zone wall date', () {
      // 23:30 UTC on Nov 2 is already Nov 3 in Tokyo, so "0 0 * * *" Tokyo
      // next runs at 15:00 UTC on Nov 3.
      final tokyo = PosixTz.tryParse('JST-9')!;
      final r = CronSchedule.tryParse('0 0 * * *')!.nextRuns(u(2026, 11, 2, 23, 30), count: 1, zone: tokyo);
      expect(r, [u(2026, 11, 3, 15)]);
    });
  });
}
