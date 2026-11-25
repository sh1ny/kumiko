import 'dart:io';

import 'package:process_containment/src/posix_process_table.dart';
import 'package:test/test.dart';

/// The kernel evidence that a process has fully exited, decoded by pure
/// functions so every OS runs these tests (issue #40, design D2).
void main() {
  group('Linux status', () {
    String status({String state = 'Z (zombie)', String? threads = '1'}) => [
      'Name:\tbash',
      'State:\t$state',
      'Tgid:\t4242',
      'Pid:\t4242',
      'Uid:\t1000\t1000\t1000\t1000',
      if (threads != null) 'Threads:\t$threads',
      'SigQ:\t0/63460',
    ].join('\n');

    test('a zombie counted as the last thread confirms', () {
      expect(linuxStatusConfirmsExit(status()), isTrue);
      expect(linuxStatusConfirmsExit(status(state: 'X (dead)')), isTrue);
    });

    test('a zombie leader with live threads does not confirm', () {
      expect(linuxStatusConfirmsExit(status(threads: '2')), isFalse);
    });

    test('a zombie with a count of 0 does not confirm', () {
      // The count is 0 when the read could not lock the signal state: it
      // says nothing about the thread group (round-4 finding).
      expect(linuxStatusConfirmsExit(status(threads: '0')), isFalse);
    });

    test('a live leader with one thread does not confirm', () {
      // After a sibling's exec, the pid belongs to a live leader.
      expect(linuxStatusConfirmsExit(status(state: 'R (running)')), isFalse);
      expect(linuxStatusConfirmsExit(status(state: 'S (sleeping)')), isFalse);
    });

    test('a status missing State or Threads does not confirm', () {
      expect(linuxStatusConfirmsExit(status(threads: null)), isFalse);
      expect(
        linuxStatusConfirmsExit(
          status().split('\n').where((l) => !l.startsWith('State:')).join('\n'),
        ),
        isFalse,
      );
      expect(linuxStatusConfirmsExit(''), isFalse);
    });
  });

  group('Linux exit decision', () {
    // The reads are injected, so ENOENT under each mount configuration is
    // decided the same way on every OS (pre-ship review round 3, F4).
    String gone() => throw const FileSystemException(
      'read',
      '/proc/4242/status',
      OSError('No such file or directory', 2),
    );
    String denied() => throw const FileSystemException(
      'read',
      '/proc/4242/status',
      OSError('Permission denied', 13),
    );
    String stat(int ticks) =>
        '4242 (sh) S 1 4242 4242 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 '
        '$ticks 0 0';

    test('ENOENT confirms only when no mount hides pids', () {
      for (final known in [null, 100]) {
        expect(
          linuxExitConfirmed(
            known,
            readStat: gone,
            readStatus: gone,
            hidden: false,
          ),
          isTrue,
          reason: 'start $known, no hidepid',
        );
        expect(
          linuxExitConfirmed(
            known,
            readStat: gone,
            readStatus: gone,
            hidden: true,
          ),
          isFalse,
          reason: 'start $known, hidepid',
        );
      }
    });

    test('another read error confirms nothing', () {
      expect(
        linuxExitConfirmed(
          100,
          readStat: denied,
          readStatus: denied,
          hidden: false,
        ),
        isFalse,
      );
    });

    test('another start time confirms; the same one reads the status', () {
      expect(
        linuxExitConfirmed(
          100,
          readStat: () => stat(200),
          readStatus: () => fail('the start time decided'),
          hidden: true,
        ),
        isTrue,
      );
      expect(
        linuxExitConfirmed(
          100,
          readStat: () => stat(100),
          readStatus: () => 'State:\tZ (zombie)\nThreads:\t1',
          hidden: true,
        ),
        isTrue,
      );
      expect(
        linuxExitConfirmed(
          100,
          readStat: () => stat(100),
          readStatus: () => 'State:\tS (sleeping)\nThreads:\t1',
          hidden: false,
        ),
        isFalse,
      );
    });
  });

  group('macOS', () {
    test('a different start time from the leaf read confirms', () {
      expect(
        macConfirmedExits(
          pids: {10: 100, 11: 100},
          readStartTimes: {10: 200, 11: 100},
          listed: {10, 11},
        ),
        {10},
      );
    });

    test('a pid absent from a complete listing confirms', () {
      expect(
        macConfirmedExits(
          pids: {10: 100, 11: null, 12: null},
          readStartTimes: const {},
          listed: {12, 99},
        ),
        {10, 11},
      );
    });

    test('a pid still listed is not confirmed, zombie or not', () {
      // An unreaped zombie is still listed (zombproc): not confirmed.
      expect(
        macConfirmedExits(
          pids: {10: 100, 11: null},
          readStartTimes: {10: 100},
          listed: {10, 11},
        ),
        isEmpty,
      );
    });

    test('a listing that threw confirms only start-time differences', () {
      expect(
        macConfirmedExits(
          pids: {10: 100, 11: 100, 12: null},
          readStartTimes: {10: 200},
          listed: null,
        ),
        {10},
      );
    });

    test('a start time read for a pid with none known confirms nothing', () {
      expect(
        macConfirmedExits(
          pids: {10: null},
          readStartTimes: {10: 200},
          listed: {10},
        ),
        isEmpty,
      );
    });
  });

  group('macOS foreign pids', () {
    test(
      "a pid absent from our user's listing and still listed is foreign",
      () {
        expect(
          macForeignPids(
            {10, 11, 12},
            ownListing: {11, 99},
            laterListing: {10, 11, 12, 99},
          ),
          {10, 12},
        );
      },
    );

    test('a pid listed under our user is not foreign', () {
      expect(
        macForeignPids({11}, ownListing: {11}, laterListing: {11}),
        isEmpty,
      );
    });

    test("a pid reaped before our user's listing is not foreign", () {
      // Absent from both listings: gone, not shown to be another user's
      // (pre-ship review round 2, F1).
      expect(
        macForeignPids({10, 12}, ownListing: {99}, laterListing: {12, 99}),
        {12},
      );
    });

    test('a listing that threw names no pid', () {
      expect(
        macForeignPids({10, 11}, ownListing: null, laterListing: {10, 11}),
        isEmpty,
      );
      expect(
        macForeignPids({10, 11}, ownListing: const {}, laterListing: null),
        isEmpty,
      );
    });
  });

  group('Linux /proc mount', () {
    String mountinfo(String superOptions, {String point = '/proc'}) => [
      '23 1 8:32 / / rw,relatime shared:1 - ext4 /dev/sdc rw',
      '24 23 0:22 / $point rw,nosuid,nodev,noexec,relatime shared:12 - '
          'proc proc $superOptions',
      '25 23 0:23 / /sys rw,nosuid,nodev,noexec,relatime shared:2 - '
          'sysfs sysfs rw',
    ].join('\n');

    test('hidepid other than 0 or off hides pids', () {
      for (final value in [
        '1',
        '2',
        '4',
        'noaccess',
        'invisible',
        'ptraceable',
      ]) {
        expect(
          procHidesPids(mountinfo('rw,hidepid=$value')),
          isTrue,
          reason: value,
        );
      }
    });

    test('hidepid 0 or off, or no hidepid, does not hide pids', () {
      expect(procHidesPids(mountinfo('rw')), isFalse);
      expect(procHidesPids(mountinfo('rw,hidepid=0')), isFalse);
      expect(procHidesPids(mountinfo('rw,hidepid=off,subset=pid')), isFalse);
    });

    test('any proc mount at /proc with hidepid hides pids', () {
      // Row order does not show which stacked mount is in use, so the one
      // with hidepid is trusted wherever it is listed (pre-ship review
      // round 3, F1).
      const hiding =
          '30 24 0:40 / /proc rw,relatime shared:20 - proc proc rw,hidepid=2';
      expect(procHidesPids([mountinfo('rw'), hiding].join('\n')), isTrue);
      expect(procHidesPids([hiding, mountinfo('rw')].join('\n')), isTrue);
    });

    test('a mountinfo with no proc mount at /proc counts as hiding', () {
      expect(procHidesPids(mountinfo('rw', point: '/elsewhere')), isTrue);
      expect(procHidesPids(''), isTrue);
      expect(procHidesPids('garbage line\nmore'), isTrue);
    });
  });
}
