import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:host/src/agent/codex/native_home_audit.dart'
    show protectedNativeBasenames;
import 'package:host_protocol/host_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/codex_support.dart';
import 'support/tool_support.dart';

void main() {
  late Directory profile;
  late Directory work;
  test('Codex audit budget: default prepare echoes immutable limits and refuses stats overrides', () async {
    final home = tempDir('audit_binding_');
    addTearDown(() => deleteTree(home));
    final fixture = NativeFixture(profile, work);
    await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
    final prepared = await fixture.desktop.connection.request(
      'test/codex.audit.prepare',
      {},
    ) as Json;
    expect(prepared['auditProfile'], 'default');
    expect(prepared['maxFileBytes'], 16 * 1024 * 1024);
    await expectLater(
      fixture.desktop.connection.request('test/agent.stats', {
        'maxTotalBytes': 999,
      }),
      throwsA(isA<RpcException>()),
    );
  });

  test(
    'Codex audit budget: stats has closed keys and empty stats remains valid',
    () async {
      final fixture = NativeFixture(profile, work);
      await fixture.open();
      expect(
        await fixture.desktop.connection.request('test/agent.stats', {}),
        isA<Json>(),
      );
      for (final key in [
        'auditProfile',
        'maxFiles',
        'maxFileBytes',
        'maxTotalBytes',
        'budget',
        'other',
      ]) {
        await expectLater(
          fixture.desktop.connection.request('test/agent.stats', {
            key: 'large-native-home',
          }),
          throwsA(
            isA<RpcException>().having(
              (e) => e.reason,
              'reason',
              ErrorCode.invalidParams,
            ),
          ),
        );
      }
    },
  );
  test('Codex audit budget: unknown binding rejected and large binding echoes once', () async {
    final home = tempDir('audit_large_');
    addTearDown(() => deleteTree(home));
    final fixture = NativeFixture(profile, work);
    await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
    for (final value in ['unknown', 1, null]) {
      await expectLater(
        fixture.desktop.connection.request('test/codex.audit.prepare', {
          'auditProfile': value,
        }),
        throwsA(isA<RpcException>()),
      );
    }
    final echo = await fixture.desktop.connection.request(
      'test/codex.audit.prepare',
      {'auditProfile': 'large-native-home'},
    ) as Json;
    expect(echo['auditProfile'], 'large-native-home');
    expect(echo['maxFiles'], 4096);
    expect(echo['maxFileBytes'], 256 * 1024 * 1024);
    expect(echo['maxTotalBytes'], 512 * 1024 * 1024);
    await expectLater(
      fixture.desktop.connection.request('test/codex.audit.prepare', {}),
      throwsA(isA<RpcException>()),
    );
    final agent = await fixture.start();
    await agent.close();
    final stats = await fixture.desktop.connection.request('test/agent.stats', {
      'secretScanSessionId': agent.id,
      'secretScanRoots': [work.path],
    }) as Json;
    final audit = stats['secretAudit'] as Json;
    for (final key in [
      'auditProfile',
      'maxFiles',
      'maxFileBytes',
      'maxTotalBytes',
    ]) {
      expect(audit[key], echo[key]);
    }
    expect(audit['complete'], true);
  });
  test(
    'Codex audit budget: legacy scan uses default and prevents late binding',
    () async {
      final home = tempDir('audit_legacy_');
      addTearDown(() => deleteTree(home));
      final fixture = NativeFixture(profile, work);
      await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
      final agent = await fixture.start();
      await agent.close();
      final stats = await fixture.desktop.connection.request(
        'test/agent.stats',
        {
          'secretScanSessionId': agent.id,
          'secretScanRoots': [work.path],
        },
      ) as Json;
      final audit = stats['secretAudit'] as Json;
      expect(audit['auditProfile'], 'default');
      expect(audit['maxFileBytes'], 16 * 1024 * 1024);
      expect(audit['maxTotalBytes'], 32 * 1024 * 1024);
      await expectLater(
        fixture.desktop.connection.request('test/codex.audit.prepare', {
          'auditProfile': 'large-native-home',
        }),
        throwsA(isA<RpcException>()),
      );
    },
  );
  test(
    'Codex audit budget: attempted scan prevents later preparation',
    () async {
      final home = tempDir('audit_scanned_');
      addTearDown(() => deleteTree(home));
      final fixture = NativeFixture(profile, work);
      await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
      await expectLater(
        fixture.desktop.connection.request('test/agent.stats', {
          'secretScanSessionId': 'absent',
          'secretScanRoots': [work.path],
        }),
        throwsA(isA<RpcException>()),
      );
      await expectLater(
        fixture.desktop.connection.request('test/codex.audit.prepare', {}),
        throwsA(isA<RpcException>()),
      );
    },
  );

  /// Runs one scripted native session against an owned synthetic native home
  /// with an explicit preparation, then returns the preparation echo and the
  /// scan result. [seed] runs before preparation, [afterClose] before the scan.
  Future<({Json prepared, Json audit, Json stats, Directory home})> auditRun({
    Json? prepare = const {},
    List<String> persist = const [],
    void Function(Directory home)? seed,
    void Function(Directory home)? afterClose,
    List<Directory> Function(Directory work, Directory profile)? extraRoots,
  }) async {
    final home = tempDir('changed_artifacts_home_');
    addTearDown(() => deleteTree(home));
    // Fresh profile and workspace per run: one host owns a profile at a time.
    final ownProfile = tempDir('changed_artifacts_profile_');
    final ownWork = tempDir('changed_artifacts_work_');
    addTearDown(() => deleteTree(ownProfile));
    addTearDown(() => deleteTree(ownWork));
    seed?.call(home);
    final fixture = NativeFixture(
      ownProfile,
      ownWork,
      script: {
        'initialize': {
          'userAgent': 'codex/0.166.0',
          'platformFamily': 'windows',
          'platformOs': 'windows',
          'codexHome': home.path,
        },
        'kumikoTool': {'when': 'session/new', 'call': 'kumiko_session_info'},
        'toolsAudit': {
          'scanRoots': [home.path],
        },
        'toolsAuditHome': home.path,
        'persistSecretPaths': persist,
      },
    );
    await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
    final prepared = await fixture.desktop.connection.request(
      'test/codex.audit.prepare',
      prepare!,
    ) as Json;
    final agent = await fixture.start();
    await agent.close();
    afterClose?.call(home);
    final stats = await fixture.desktop.connection.request('test/agent.stats', {
      'secretScanSessionId': agent.id,
      'secretScanRoots': [
        home.path,
        ...?extraRoots?.call(ownWork, ownProfile).map((d) => d.path),
      ],
    }) as Json;
    return (
      prepared: prepared,
      audit: stats['secretAudit'] as Json,
      stats: stats,
      home: home,
    );
  }

  const v1 = {'nativeSelection': 'changed-artifacts-v1'};
  String join(Directory home, String relative) =>
      p.joinAll([home.path, ...relative.split('/')]);
  void writeAt(Directory home, String relative, [String content = 'x']) {
    final file = File(join(home, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  test('Codex changed artifacts: selection scans a new model cache and unclassified descendants through the one scanner', () async {
    final run = await auditRun(
      prepare: v1,
      persist: ['models_cache.json', 'unclassified/deep/cache.bin'],
      seed: (home) => writeAt(home, 'PRIVATE_DIR/PRIVATE_FILE', 'PRIVATE_BODY'),
    );
    expect(run.audit['complete'], true, reason: '${run.audit}');
    expect(run.audit['matchedFiles'], 2);
    expect(run.audit['nativeSelection'], 'changed-artifacts-v1');
    expect(run.audit['maxFileBytes'], 16 * 1024 * 1024);
    expect(run.audit['maxTotalBytes'], 32 * 1024 * 1024);
    expect(
      (run.audit['nativeDetectorLimits'] as List).join(' '),
      allOf(contains('metadata'), contains('ASCII'), contains('UTF-8')),
    );
    final counters = run.audit['nativeSelectionCounters'] as Json;
    expect(counters['changedFiles'], greaterThanOrEqualTo(2));
    final text = jsonEncode(run.stats);
    expect(text, isNot(contains('PRIVATE')));
    expect(text, isNot(contains('KUMIKO_TOOL_SECRET')));
    expect(text, isNot(contains(run.home.path)));
  });
  test('Codex changed artifacts: selection always scans SQLite family files in unclassified directories without a metadata change', () async {
    final run = await auditRun(
      prepare: v1,
      seed: (home) {
        writeAt(home, 'unclassified/db.sqlite');
        writeAt(home, 'unclassified/db.sqlite-wal');
        writeAt(home, 'unclassified/db.sqlite-shm');
        writeAt(home, 'unclassified/plain.bin');
      },
    );
    expect(run.audit['complete'], true, reason: '${run.audit}');
    final counters = run.audit['nativeSelectionCounters'] as Json;
    expect(counters['alwaysScanFiles'], greaterThanOrEqualTo(3));
    // Three always-scanned unchanged files plus the fixture's own new files;
    // the metadata-equal ordinary file stays unread.
    final scanned = run.audit['scannedFiles'] as int;
    expect(scanned, counters['selectedFiles']);
    expect(
      (run.audit['nativeDetectorLimits'] as List).join(' '),
      contains('metadata'),
    );
  });

  test('Codex changed artifacts: binding absent selection keeps legacy coverage and echoes baseline counters', () async {
    final run = await auditRun(persist: ['models_cache.json']);
    expect(run.prepared['nativeSelection'], 'legacy');
    expect(run.prepared['baselineComplete'], true);
    expect(run.prepared['baselineErrorCount'], 0);
    expect(run.audit['nativeSelection'], 'legacy');
    expect(run.audit.containsKey('nativeDetectorLimits'), false);
    // Legacy still refuses the unclassified cache instead of reading it.
    expect(run.audit['complete'], false);
    expect(run.audit['matchedFiles'], 0);
    final explicit = await auditRun(
      prepare: {'nativeSelection': 'legacy'},
      persist: ['models_cache.json'],
    );
    expect(explicit.prepared['nativeSelection'], 'legacy');
    expect(explicit.audit['complete'], false);
    expect(explicit.audit['matchedFiles'], 0);
  });
  test('Codex changed artifacts: binding explicit selection is echoed at preparation and every scan', () async {
    final run = await auditRun(
      prepare: {...v1, 'auditProfile': 'large-native-home'},
    );
    expect(run.prepared['nativeSelection'], 'changed-artifacts-v1');
    expect(run.prepared['auditProfile'], 'large-native-home');
    expect(run.prepared['baselineComplete'], true);
    expect(run.prepared['baselineErrorCount'], 0);
    expect(run.audit['nativeSelection'], 'changed-artifacts-v1');
    expect(run.audit['auditProfile'], 'large-native-home');
  });
  test('Codex changed artifacts: binding unknown non-string and extra values are refused without consuming the preparation', () async {
    final home = tempDir('changed_artifacts_invalid_');
    addTearDown(() => deleteTree(home));
    final fixture = NativeFixture(profile, work);
    await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
    for (final value in <Object?>[
      'unknown',
      'Changed-Artifacts-V1',
      'changed-artifacts-v5',
      '',
      1,
      null,
      true,
      ['changed-artifacts-v1'],
    ]) {
      await expectLater(
        fixture.desktop.connection.request('test/codex.audit.prepare', {
          'nativeSelection': value,
        }),
        throwsA(
          isA<RpcException>().having(
            (e) => e.reason,
            'reason',
            ErrorCode.invalidParams,
          ),
        ),
        reason: '$value',
      );
    }
    for (final extra in ['budget', 'protectedNames', 'maxFiles', 'walk']) {
      await expectLater(
        fixture.desktop.connection.request('test/codex.audit.prepare', {
          'nativeSelection': 'legacy',
          extra: 1,
        }),
        throwsA(isA<RpcException>()),
        reason: extra,
      );
    }
    final echo = await fixture.desktop.connection.request(
      'test/codex.audit.prepare',
      v1,
    ) as Json;
    expect(echo['nativeSelection'], 'changed-artifacts-v1');
  });
  test('Codex changed artifacts: binding is once-only and refused late or repeated', () async {
    final home = tempDir('changed_artifacts_once_');
    addTearDown(() => deleteTree(home));
    final fixture = NativeFixture(profile, work);
    await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
    await fixture.desktop.connection.request('test/codex.audit.prepare', v1);
    for (final params in [
      v1,
      {'nativeSelection': 'legacy'},
      <String, Object?>{},
    ]) {
      await expectLater(
        fixture.desktop.connection.request('test/codex.audit.prepare', params),
        throwsA(isA<RpcException>()),
      );
    }
    final late = tempDir('changed_artifacts_late_');
    addTearDown(() => deleteTree(late));
    final lateProfile = tempDir('changed_artifacts_late_profile_');
    final lateWork = tempDir('changed_artifacts_late_work_');
    addTearDown(() => deleteTree(lateProfile));
    addTearDown(() => deleteTree(lateWork));
    final scanned = NativeFixture(lateProfile, lateWork);
    await scanned.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': late.path});
    await expectLater(
      scanned.desktop.connection.request('test/agent.stats', {
        'secretScanSessionId': 'absent',
        'secretScanRoots': [lateWork.path],
      }),
      throwsA(isA<RpcException>()),
    );
    await expectLater(
      scanned.desktop.connection.request('test/codex.audit.prepare', v1),
      throwsA(isA<RpcException>()),
    );
  });
  test(
    'Codex changed artifacts: binding stats refuses any selection override',
    () async {
      final home = tempDir('changed_artifacts_stats_');
      addTearDown(() => deleteTree(home));
      final fixture = NativeFixture(profile, work);
      await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
      await fixture.desktop.connection.request('test/codex.audit.prepare', v1);
      for (final value in <Object?>[
        'changed-artifacts-v1',
        'legacy',
        1,
        null,
      ]) {
        await expectLater(
          fixture.desktop.connection.request('test/agent.stats', {
            'nativeSelection': value,
          }),
          throwsA(
            isA<RpcException>().having(
              (e) => e.reason,
              'reason',
              ErrorCode.invalidParams,
            ),
          ),
        );
      }
      expect(
        await fixture.desktop.connection.request('test/agent.stats', {}),
        isA<Json>(),
      );
    },
  );
  test('Codex changed artifacts: binding an incomplete wider baseline is echoed and sticks with no legacy fallback', () async {
    final home = tempDir('changed_artifacts_baseline_');
    addTearDown(() => deleteTree(home));
    for (var i = 0; i < 4100; i++) {
      File(join(home, 'bulk/f$i')).createSync(recursive: true);
    }
    final fixture = NativeFixture(profile, work);
    await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
    final echo = await fixture.desktop.connection.request(
      'test/codex.audit.prepare',
      v1,
    ) as Json;
    expect(echo['nativeSelection'], 'changed-artifacts-v1');
    expect(echo['baselineComplete'], false);
    expect(echo['baselineErrorCount'], greaterThan(0));
    // Content-free category counters explain an incomplete baseline.
    final categories = echo['baselineErrorCategories']! as Json;
    expect(categories['metadataLimit'], greaterThan(0));
    expect(
      categories.values.fold<int>(0, (sum, v) => sum + (v! as int)),
      echo['baselineErrorCount'],
    );
    expect(echo['baselineIoErrorCategories'], isA<Json>());
    expect(jsonEncode(echo), isNot(contains('bulk')));
    await expectLater(
      fixture.desktop.connection.request('test/codex.audit.prepare', {
        'nativeSelection': 'legacy',
      }),
      throwsA(isA<RpcException>()),
    );
  });

  test('Codex changed artifacts: refusal protected leaves holding the run secret are never read under any path', () async {
    final run = await auditRun(
      prepare: v1,
      persist: [
        'state/auth.json',
        'unclassified/deep/config.toml',
        '.env',
        'logs/.credentials.json',
      ],
    );
    expect(run.audit['complete'], false);
    expect(run.audit['matchedFiles'], 0, reason: 'protected bytes were read');
    final categories = run.audit['nativeErrorCategories'] as Json;
    expect(categories['protectedEntry'], 4);
    final text = jsonEncode(run.stats);
    for (final name in protectedNativeBasenames) {
      expect(text, isNot(contains(name)));
    }
  });
  test('Codex changed artifacts: refusal changed and removed protected entries and removed ordinary entries stay incomplete', () async {
    final run = await auditRun(
      prepare: v1,
      seed: (home) {
        writeAt(home, 'auth.json');
        writeAt(home, 'state/.credentials.json');
        writeAt(home, 'plain.bin');
      },
      afterClose: (home) {
        File(join(home, 'auth.json')).deleteSync();
        writeAt(home, 'state/.credentials.json', 'changed and longer');
        File(join(home, 'plain.bin')).deleteSync();
      },
    );
    expect(run.audit['complete'], false);
    final categories = run.audit['nativeErrorCategories'] as Json;
    expect(categories['protectedEntry'], 2);
    expect(categories['removedEntry'], 1);
  });
  test('Codex changed artifacts: refusal links and metadata admission overflow stay incomplete', () async {
    final outside = tempDir('changed_artifacts_link_target_');
    addTearDown(() => deleteTree(outside));
    File(p.join(outside.path, 'target.bin')).writeAsStringSync('synthetic');
    final linked = await auditRun(
      prepare: v1,
      afterClose: (home) {
        Directory(join(home, 'unclassified')).createSync();
        Link(join(home, 'unclassified/link')).createSync(outside.path);
      },
    );
    expect(linked.audit['complete'], false);
    expect((linked.audit['nativeErrorCategories'] as Json)['nonRegular'], 1);
    final overflow = await auditRun(
      prepare: v1,
      afterClose: (home) {
        for (var i = 0; i < 4100; i++) {
          File(join(home, 'bulk/f$i')).createSync(recursive: true);
        }
      },
    );
    expect(overflow.audit['complete'], false);
    expect(
      (overflow.audit['nativeErrorCategories'] as Json)['metadataLimit'],
      greaterThanOrEqualTo(1),
    );
  });
  test('Codex changed artifacts: refusal oversize changed files keep the unchanged byte limits', () async {
    final run = await auditRun(
      prepare: v1,
      afterClose: (home) =>
          File(join(home, 'big.bin'))
              .writeAsBytesSync(Uint8List(16 * 1024 * 1024 + 1)),
    );
    expect(run.audit['complete'], false);
    expect((run.audit['errorCategories'] as Json)['fileLimit'], 1);
    expect(run.audit['maxFileBytes'], 16 * 1024 * 1024);
    expect(
      run.audit['readBytes'] as int,
      lessThanOrEqualTo(run.audit['chargedBytes'] as int),
    );
  });

  // ---- Codex normal home: changed-artifacts-v2 ----
  const v2 = {'nativeSelection': 'changed-artifacts-v2'};
  void makeLink(String link, String target) {
    if (Platform.isWindows) {
      final result = Process.runSync('cmd', [
        '/c',
        'mklink',
        '/J',
        link.replaceAll('/', r'\'),
        target.replaceAll('/', r'\'),
      ]);
      if (result.exitCode != 0) throw StateError('junction fixture failed');
    } else {
      Link(link).createSync(target);
    }
  }

  void dropLink(String path) {
    try {
      Link(path).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  test('Codex normal home: a home beyond 4096 entries completes and the v2 selection and limits are echoed', () async {
    final run = await auditRun(
      prepare: v2,
      persist: ['models_cache.json'],
      seed: (home) {
        for (var i = 0; i < 4200; i++) {
          File(join(home, 'bulk/f$i')).createSync(recursive: true);
        }
        writeAt(home, 'PRIVATE_DIR/PRIVATE_FILE', 'PRIVATE_BODY');
      },
    );
    expect(run.prepared['nativeSelection'], 'changed-artifacts-v2');
    expect(run.prepared['baselineComplete'], true, reason: '${run.prepared}');
    expect(run.prepared['baselineErrorCount'], 0);
    final baseline = run.prepared['baselineErrorCategories']! as Json;
    expect(baseline['metadataStorage'], 0);
    expect(baseline['linkObservation'], 0);
    expect(run.audit['nativeSelection'], 'changed-artifacts-v2');
    expect(run.audit['complete'], true, reason: '${run.audit}');
    expect(run.audit['matchedFiles'], 1);
    expect(run.audit['maxFiles'], 4096, reason: 'scanner limits are unchanged');
    expect(run.audit['maxFileBytes'], 16 * 1024 * 1024);
    final limits = (run.audit['nativeDetectorLimits'] as List).join(' ');
    expect(limits, allOf(contains('metadata'), contains('ASCII')));
    expect(
      limits,
      allOf(contains('unchanged-link'), contains('other Codex sessions')),
    );
    final categories = run.audit['nativeErrorCategories']! as Json;
    expect(categories['metadataStorage'], 0);
    expect(categories['linkObservation'], 0);
    final counters = run.audit['nativeSelectionCounters']! as Json;
    expect(counters['inventoryEntries'], greaterThan(4096));
    final text = jsonEncode(run.stats) + jsonEncode(run.prepared);
    expect(text, isNot(contains('PRIVATE')));
    expect(text, isNot(contains(run.home.path)));
  });
  test(
    'Codex normal home: an unchanged real link is accounted for and its target is neither followed nor emitted',
    () async {
      final outside = tempDir('normal_home_target_');
      addTearDown(() => deleteTree(outside));
      writeAt(outside, 'PRIVATE_BEHIND_LINK', 'PRIVATE_BODY');
      late String link;
      final run = await auditRun(
        prepare: v2,
        persist: ['models_cache.json'],
        seed: (home) {
          link = join(home, 'PRIVATE_LINK');
          makeLink(link, outside.path);
          addTearDown(() => dropLink(link));
        },
      );
      expect(run.prepared['baselineComplete'], true, reason: '${run.prepared}');
      expect(run.audit['complete'], true, reason: '${run.audit}');
      expect(run.audit['matchedFiles'], 1);
      final counters = run.audit['nativeSelectionCounters']! as Json;
      expect(counters['linksAccounted'], 1);
      final text = jsonEncode(run.stats) + jsonEncode(run.prepared);
      for (final secret in ['PRIVATE', outside.path, run.home.path]) {
        expect(text, isNot(contains(secret)));
      }
    },
    skip: Platform.isWindows ? false : 'real link observation is Windows-only',
  );
  test(
    'Codex normal home: added removed and retargeted real links keep the audit incomplete',
    () async {
      final first = tempDir('normal_home_first_');
      final second = tempDir('normal_home_second_');
      addTearDown(() => deleteTree(first));
      addTearDown(() => deleteTree(second));
      Future<Json> categoriesAfter({
        required bool existing,
        required void Function(String link) change,
      }) async {
        final run = await auditRun(
          prepare: v2,
          seed: (home) {
            if (existing) {
              makeLink(join(home, 'link'), first.path);
              addTearDown(() => dropLink(join(home, 'link')));
            }
          },
          afterClose: (home) {
            addTearDown(() => dropLink(join(home, 'link')));
            change(join(home, 'link'));
          },
        );
        expect(run.audit['complete'], false);
        return run.audit['nativeErrorCategories']! as Json;
      }

      final added = await categoriesAfter(
        existing: false,
        change: (link) => makeLink(link, first.path),
      );
      expect(added['changedUnknownFile'], 1);
      final removed = await categoriesAfter(existing: true, change: dropLink);
      expect(removed['removedEntry'], 1);
      final retargeted = await categoriesAfter(
        existing: true,
        change: (link) {
          dropLink(link);
          makeLink(link, second.path);
        },
      );
      expect(retargeted['changedUnknownFile'], 1);
    },
    skip: Platform.isWindows ? false : 'real link observation is Windows-only',
  );
  test('Codex normal home: links in the workspace and profile roots are still refused', () async {
    final outside = tempDir('normal_home_root_target_');
    addTearDown(() => deleteTree(outside));
    for (final inProfile in [false, true]) {
      final run = await auditRun(
        prepare: v2,
        extraRoots: (work, profile) {
          final root = inProfile ? profile : work;
          final link = p.join(root.path, 'link');
          makeLink(link, outside.path);
          addTearDown(() => dropLink(link));
          return [root];
        },
      );
      expect(run.audit['complete'], false, reason: 'profile=$inProfile');
      expect(
        (run.audit['errorCategories'] as Json)['nonRegular'],
        1,
        reason: 'profile=$inProfile ${run.audit['errorCategories']}',
      );
    }
  });
  test('Codex normal home: binding echoes v2 once and refuses a repeat or a stats override', () async {
    final home = tempDir('normal_home_binding_');
    addTearDown(() => deleteTree(home));
    final fixture = NativeFixture(profile, work);
    await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
    final echo = await fixture.desktop.connection.request(
      'test/codex.audit.prepare',
      {...v2, 'auditProfile': 'large-native-home'},
    ) as Json;
    expect(echo['nativeSelection'], 'changed-artifacts-v2');
    expect(echo['auditProfile'], 'large-native-home');
    expect(echo['baselineComplete'], true);
    for (final params in <Json>[
      v2,
      {'nativeSelection': 'changed-artifacts-v1'},
      {'nativeSelection': 'legacy'},
      <String, Object?>{},
      {...v2, 'budget': 1},
      {...v2, 'maxFiles': 65536},
    ]) {
      await expectLater(
        fixture.desktop.connection.request('test/codex.audit.prepare', params),
        throwsA(isA<RpcException>()),
        reason: '$params',
      );
    }
    for (final value in <Object?>['changed-artifacts-v2', 'legacy', 1, null]) {
      await expectLater(
        fixture.desktop.connection.request('test/agent.stats', {
          'nativeSelection': value,
        }),
        throwsA(isA<RpcException>()),
      );
    }
  });
  test('Codex normal home: changed-artifacts-v1 results are byte-identical in limits and categories', () async {
    final run = await auditRun(prepare: v1);
    expect(run.audit['nativeDetectorLimits'], [
      'metadata-equality: unchanged ordinary files outside the always-scan set are not read',
      'ASCII/UTF-8: only the ASCII canary encoded as UTF-8 bytes is matched',
    ]);
    final categories = run.audit['nativeErrorCategories']! as Json;
    expect(categories.containsKey('metadataStorage'), false);
    expect(categories.containsKey('linkObservation'), false);
    expect(
      (run.audit['nativeSelectionCounters'] as Json).containsKey(
        'linksAccounted',
      ),
      false,
    );
    expect(
      (run.prepared['baselineErrorCategories'] as Json).containsKey(
        'linkObservation',
      ),
      false,
    );
  });

  // ---- Codex native sockets: changed-artifacts-v3 ----
  const v3 = {'nativeSelection': 'changed-artifacts-v3'};

  test('Codex native sockets: v3 preparation and result echo the selection the socket limit and the socket counters', () async {
    final run = await auditRun(
      prepare: v3,
      persist: ['models_cache.json'],
      seed: (home) {
        for (var i = 0; i < 4200; i++) {
          File(join(home, 'bulk/f$i')).createSync(recursive: true);
        }
        writeAt(home, 'PRIVATE_DIR/PRIVATE_FILE', 'PRIVATE_BODY');
      },
    );
    expect(run.prepared['nativeSelection'], 'changed-artifacts-v3');
    expect(run.prepared['baselineComplete'], true, reason: '${run.prepared}');
    expect(run.prepared['baselineErrorCount'], 0);
    final baseline = run.prepared['baselineErrorCategories']! as Json;
    expect(baseline['metadataStorage'], 0);
    expect(baseline['linkObservation'], 0);
    expect(baseline['nonRegular'], 0);
    expect(run.audit['nativeSelection'], 'changed-artifacts-v3');
    expect(run.audit['complete'], true, reason: '${run.audit}');
    expect(run.audit['matchedFiles'], 1);
    expect(run.audit['maxFiles'], 4096, reason: 'scanner limits are unchanged');
    final limits = (run.audit['nativeDetectorLimits'] as List).join(' ');
    expect(
      limits,
      allOf(
        contains('unchanged-link'),
        contains('other Codex sessions'),
        contains('sockets:'),
      ),
    );
    final categories = run.audit['nativeErrorCategories']! as Json;
    expect(categories['linkObservation'], 0);
    final counters = run.audit['nativeSelectionCounters']! as Json;
    expect(counters['inventoryEntries'], greaterThan(4096));
    expect(counters['linksAccounted'], 0);
    expect(counters['socketsAccounted'], 0);
    expect(counters['socketsChanged'], 0);
    final text = jsonEncode(run.stats) + jsonEncode(run.prepared);
    expect(text, isNot(contains('PRIVATE')));
    expect(text, isNot(contains(run.home.path)));
  });
  test(
    'Codex native sockets: v2 results never carry a socket counter or limit',
    () async {
      final run = await auditRun(prepare: v2);
      final counters = run.audit['nativeSelectionCounters']! as Json;
      expect(counters.containsKey('socketsAccounted'), false);
      expect(counters.containsKey('socketsChanged'), false);
      expect(
        (run.audit['nativeDetectorLimits'] as List).join(' '),
        isNot(contains('socket')),
      );
    },
  );
  test('Codex native sockets: binding echoes v3 once and refuses a repeat another selection or a stats override', () async {
    final home = tempDir('native_sockets_binding_');
    addTearDown(() => deleteTree(home));
    final fixture = NativeFixture(profile, work);
    await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
    final echo = await fixture.desktop.connection.request(
      'test/codex.audit.prepare',
      {...v3, 'auditProfile': 'large-native-home'},
    ) as Json;
    expect(echo['nativeSelection'], 'changed-artifacts-v3');
    expect(echo['auditProfile'], 'large-native-home');
    expect(echo['baselineComplete'], true);
    for (final params in <Json>[
      v3,
      v2,
      {'nativeSelection': 'changed-artifacts-v1'},
      {'nativeSelection': 'legacy'},
      {'nativeSelection': 'changed-artifacts-v5'},
      <String, Object?>{},
      {...v3, 'budget': 1},
      {...v3, 'maxFiles': 65536},
    ]) {
      await expectLater(
        fixture.desktop.connection.request('test/codex.audit.prepare', params),
        throwsA(isA<RpcException>()),
        reason: '$params',
      );
    }
    for (final value in <Object?>['changed-artifacts-v3', 'legacy', 1, null]) {
      await expectLater(
        fixture.desktop.connection.request('test/agent.stats', {
          'nativeSelection': value,
        }),
        throwsA(isA<RpcException>()),
      );
    }
  });
  test('Codex native sockets: binding an incomplete v3 baseline is echoed content-free and sticks with no fallback', () async {
    final home = tempDir('native_sockets_baseline_');
    addTearDown(() => deleteTree(home));
    // A relative path beyond 4096 bytes is unadmitted in the v3 inventory. The
    // extended-length form lets Windows create a path this deep.
    final deep = [for (var i = 0; i < 22; i++) 'PRIVATE_${'d' * 192}_$i'];
    final deepPath = p.joinAll([home.path, ...deep]);
    addTearDown(() {
      try {
        Directory(Platform.isWindows ? '\\\\?\\${home.path}' : home.path)
            .deleteSync(recursive: true);
      } on FileSystemException {
        // Already gone.
      }
    });
    Directory(Platform.isWindows ? '\\\\?\\$deepPath' : deepPath)
        .createSync(recursive: true);
    final fixture = NativeFixture(profile, work);
    await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
    final echo = await fixture.desktop.connection.request(
      'test/codex.audit.prepare',
      v3,
    ) as Json;
    expect(echo['nativeSelection'], 'changed-artifacts-v3');
    expect(echo['baselineComplete'], false, reason: '$echo');
    expect(echo['baselineErrorCount'], greaterThan(0));
    final categories = echo['baselineErrorCategories']! as Json;
    expect(
      categories.values.fold<int>(0, (sum, v) => sum + (v! as int)),
      echo['baselineErrorCount'],
    );
    expect(jsonEncode(echo), isNot(contains('PRIVATE')));
    await expectLater(
      fixture.desktop.connection.request('test/codex.audit.prepare', {
        'nativeSelection': 'legacy',
      }),
      throwsA(isA<RpcException>()),
    );
    await expectLater(
      fixture.desktop.connection.request('test/codex.audit.prepare', v3),
      throwsA(isA<RpcException>()),
    );
  });

  // ---- Codex removed entries: changed-artifacts-v4 ----
  const v4 = {'nativeSelection': 'changed-artifacts-v4'};

  test('Codex removed entries: v4 echoes the selection the removal limit and counts a removed entry without an error while the canary still matches', () async {
    final run = await auditRun(
      prepare: v4,
      persist: ['models_cache.json'],
      seed: (home) {
        writeAt(home, 'PRIVATE_DIR/PRIVATE_TMP', 'PRIVATE_BODY');
        writeAt(home, 'PRIVATE_LOCK', 'x');
      },
      afterClose: (home) {
        File(join(home, 'PRIVATE_DIR/PRIVATE_TMP')).deleteSync();
        File(join(home, 'PRIVATE_LOCK')).deleteSync();
      },
    );
    expect(run.prepared['nativeSelection'], 'changed-artifacts-v4');
    expect(run.prepared['baselineComplete'], true, reason: '${run.prepared}');
    expect(run.audit['nativeSelection'], 'changed-artifacts-v4');
    expect(run.audit['complete'], true, reason: '${run.audit}');
    expect(run.audit['matchedFiles'], 1);
    final counters = run.audit['nativeSelectionCounters']! as Json;
    expect(counters['removedEntries'], 2);
    expect(counters['socketsChanged'], 0);
    final categories = run.audit['nativeErrorCategories']! as Json;
    expect(categories['removedEntry'], 0);
    expect(categories['protectedEntry'], 0);
    final limits = (run.audit['nativeDetectorLimits'] as List).join(' ');
    expect(limits, allOf(contains('sockets:'), contains('removals:')));
    final text = jsonEncode(run.stats) + jsonEncode(run.prepared);
    expect(text, isNot(contains('PRIVATE')));
    expect(text, isNot(contains(run.home.path)));
  });
  test('Codex removed entries: a removed protected entry still makes the v4 audit incomplete and v3 keeps removedEntry', () async {
    final protectedRun = await auditRun(
      prepare: v4,
      seed: (home) => writeAt(home, 'auth.json', 'x'),
      afterClose: (home) => File(join(home, 'auth.json')).deleteSync(),
    );
    expect(protectedRun.audit['complete'], false);
    final categories = protectedRun.audit['nativeErrorCategories']! as Json;
    expect(categories['protectedEntry'], 1);
    expect(categories['removedEntry'], 0);
    final v3Run = await auditRun(
      prepare: v3,
      seed: (home) => writeAt(home, 'PRIVATE_LOCK', 'x'),
      afterClose: (home) => File(join(home, 'PRIVATE_LOCK')).deleteSync(),
    );
    expect(v3Run.audit['complete'], false);
    expect((v3Run.audit['nativeErrorCategories']! as Json)['removedEntry'], 1);
    expect(
      (v3Run.audit['nativeSelectionCounters']! as Json).containsKey(
        'removedEntries',
      ),
      false,
    );
  });
  test('Codex removed entries: binding echoes v4 once and refuses a repeat another selection or a stats override', () async {
    final home = tempDir('removed_entries_binding_');
    addTearDown(() => deleteTree(home));
    final fixture = NativeFixture(profile, work);
    await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
    final echo = await fixture.desktop.connection.request(
      'test/codex.audit.prepare',
      {...v4, 'auditProfile': 'large-native-home'},
    ) as Json;
    expect(echo['nativeSelection'], 'changed-artifacts-v4');
    expect(echo['auditProfile'], 'large-native-home');
    expect(echo['baselineComplete'], true);
    for (final params in <Json>[
      v4,
      v3,
      v2,
      {'nativeSelection': 'legacy'},
      {'nativeSelection': 'changed-artifacts-v5'},
      <String, Object?>{},
      {...v4, 'budget': 1},
    ]) {
      await expectLater(
        fixture.desktop.connection.request('test/codex.audit.prepare', params),
        throwsA(isA<RpcException>()),
        reason: '$params',
      );
    }
    for (final value in <Object?>['changed-artifacts-v4', 'legacy', 1, null]) {
      await expectLater(
        fixture.desktop.connection.request('test/agent.stats', {
          'nativeSelection': value,
        }),
        throwsA(isA<RpcException>()),
      );
    }
  });
  test('Codex removed entries: binding an incomplete v4 baseline is refused as incomplete and sticks with no fallback', () async {
    final home = tempDir('removed_entries_baseline_');
    addTearDown(() => deleteTree(home));
    final deep = [for (var i = 0; i < 22; i++) 'PRIVATE_${'d' * 192}_$i'];
    final deepPath = p.joinAll([home.path, ...deep]);
    addTearDown(() {
      try {
        Directory(Platform.isWindows ? '\\\\?\\${home.path}' : home.path)
            .deleteSync(recursive: true);
      } on FileSystemException {
        // Already gone.
      }
    });
    Directory(Platform.isWindows ? '\\\\?\\$deepPath' : deepPath)
        .createSync(recursive: true);
    final fixture = NativeFixture(profile, work);
    await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
    final echo = await fixture.desktop.connection.request(
      'test/codex.audit.prepare',
      v4,
    ) as Json;
    expect(echo['nativeSelection'], 'changed-artifacts-v4');
    expect(echo['baselineComplete'], false, reason: '$echo');
    expect(echo['baselineErrorCount'], greaterThan(0));
    expect(jsonEncode(echo), isNot(contains('PRIVATE')));
    await expectLater(
      fixture.desktop.connection.request('test/codex.audit.prepare', {
        'nativeSelection': 'legacy',
      }),
      throwsA(isA<RpcException>()),
    );
    await expectLater(
      fixture.desktop.connection.request('test/codex.audit.prepare', v4),
      throwsA(isA<RpcException>()),
    );
  });

  test('Codex: native home diagnostic requires immutable opt-in and initialized home', () async {
    final home = tempDir('qualification_bound_home_');
    final other = tempDir('qualification_other_home_');
    addTearDown(() => deleteTree(home));
    addTearDown(() => deleteTree(other));
    final fixture = NativeFixture(
      profile,
      work,
      script: {
        'initialize': {
          'userAgent': 'codex/0.166.0',
          'platformFamily': 'windows',
          'platformOs': 'windows',
          'codexHome': other.path,
        },
      },
    );
    await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
    await fixture.desktop.connection.request('test/codex.audit.prepare', {});
    final agent = await fixture.start();
    await agent.close();
    await expectLater(
      fixture.desktop.connection.request('test/agent.stats', {
        'secretScanSessionId': agent.id,
        'secretScanRoots': [home.path],
      }),
      throwsA(
        isA<RpcException>().having(
          (e) => e.message,
          'message',
          contains('differs'),
        ),
      ),
    );
  });
  test('Codex: independent MCP probe records its stages as booleans before any call', () async {
    final report = File(p.join(work.path, 'env-stages.json'));
    final process = await Process.start(
      testHostExecutable(),
      ['--test-fixture', 'qualification-mcp-env', '--report', report.path],
      environment: {'KUMIKO_TOOL_SECRET': 'fixture-probe-canary-not-a-grant'},
    );
    Future<Json> stageReport(bool Function(Json) reached) async {
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (true) {
        if (await report.exists()) {
          try {
            final facts = jsonDecode(await report.readAsString()) as Json;
            if (reached(facts)) return facts;
          } on FormatException {
            // A write in progress; read again.
          }
        }
        if (DateTime.now().isAfter(end)) {
          throw TimeoutException('probe stage');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    final output = StringBuffer();
    final done = process.stdout.transform(utf8.decoder).forEach(output.write);
    try {
      final started = await stageReport((facts) => facts['started'] == true);
      expect(started, {
        'started': true,
        'pid': process.pid,
        'startTime': isA<int>(),
      });
      process.stdin.writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, Object?>{},
        }),
      );
      await stageReport((facts) => facts['initialized'] == true);
      process.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
      );
      final listed = await stageReport((facts) => facts['listed'] == true);
      expect(listed['called'], isNot(true));
      expect(listed['initialized'], true);
      process.stdin.writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'tools/call',
          'params': {'name': 'env_presence', 'arguments': <String, Object?>{}},
        }),
      );
      await process.stdin.close();
      expect(await process.exitCode, 0);
      await done;
      final called = jsonDecode(await report.readAsString()) as Json;
      expect(called, containsPair('called', true));
      expect(called, containsPair('started', true));
      expect(called, containsPair('initialized', true));
      expect(called, containsPair('listed', true));
      expect(called['pid'], process.pid);
      expect(
        '$output${await report.readAsString()}',
        isNot(contains('fixture-probe-canary-not-a-grant')),
      );
      // Codex's default ("auto") MCP approval mode asks for approval of a
      // tool without annotations; the probe only reads environment presence,
      // so it says so, as Kumiko's own read-only tools do.
      final listing = [
        for (final line in const LineSplitter().convert(output.toString()))
          jsonDecode(line) as Json,
      ].singleWhere((reply) => reply['id'] == 2);
      final tools = (listing['result']! as Json)['tools']! as List;
      expect((tools.single as Json)['annotations'], {
        'readOnlyHint': true,
        'destructiveHint': false,
        'openWorldHint': false,
      });
    } finally {
      process.kill();
      await process.exitCode;
    }
  });
  test('Codex: independent MCP probe records only booleans and actual tool-call identity', () async {
    final report = File(p.join(work.path, 'env-presence.json'));
    final process = await Process.start(
      testHostExecutable(),
      ['--test-fixture', 'qualification-mcp-env', '--report', report.path],
      environment: {'KUMIKO_TOOL_SECRET': 'fixture-probe-canary-not-a-grant'},
    );
    try {
      process.stdin.writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {'name': 'env_presence', 'arguments': <String, Object?>{}},
        }),
      );
      await process.stdin.close();
      final output = await utf8.decodeStream(process.stdout);
      final errors = await utf8.decodeStream(process.stderr);
      expect(await process.exitCode, 0, reason: errors);
      final facts = jsonDecode(await report.readAsString()) as Json;
      expect(facts['called'], true);
      expect(facts['secretPresent'], true);
      expect(facts['pid'], process.pid);
      expect(facts['startTime'], isA<int>());
      expect(
        '$output${await report.readAsString()}',
        isNot(contains('fixture-probe-canary-not-a-grant')),
      );
    } finally {
      process.kill();
      await process.exitCode;
    }
  });
  test(
    'Codex: opt-in native home audit is bound and finds a persisted run secret',
    () async {
      final home = tempDir('qualification_native_home_');
      addTearDown(() => deleteTree(home));
      Directory(p.join(home.path, 'sessions')).createSync();
      Directory(p.join(home.path, 'log')).createSync();
      final fixture = NativeFixture(
        profile,
        work,
        script: {
          'initialize': {
            'userAgent': 'codex/0.166.0',
            'platformFamily': 'windows',
            'platformOs': 'windows',
            'codexHome': home.path,
          },
          'kumikoTool': {'when': 'session/new', 'call': 'kumiko_session_info'},
          'toolsAudit': {
            'scanRoots': [home.path],
          },
          'toolsAuditHome': home.path,
          'persistSecretForScanTest': true,
        },
      );
      await fixture.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
      final prepared = await fixture.desktop.connection.request(
        'test/codex.audit.prepare',
        {},
      ) as Json;
      expect(prepared['complete'], true);
      final agent = await fixture.start();
      await agent.close();
      final clean = await fixture.desktop.connection.request(
        'test/agent.stats',
        {
          'secretScanSessionId': agent.id,
          'secretScanRoots': [home.path, profile.path, work.path],
        },
      ) as Json;
      expect((clean['secretAudit'] as Json)['complete'], true);
      expect((clean['secretAudit'] as Json)['matchedFiles'], 1);
      expect(jsonEncode(clean), isNot(contains('KUMIKO_TOOL_SECRET')));
    },
  );
  setUpAll(buildTestHost);
  setUp(() {
    profile = tempDir('codex_tools_profile_');
    work = tempDir('codex_tools_work_');
  });
  tearDown(() async {
    killReported(work);
    killReported(profile);
    await deleteTree(work);
    await deleteTree(profile);
  });

  Future<(NativeFixture, AgentPeer)> start({
    Json script = const {},
    Map<String, String> environment = const {},
  }) async {
    final fixture = NativeFixture(profile, work, script: script);
    await fixture.open(env: environment);
    return (fixture, await fixture.start());
  }

  Future<bool> hasGrant(NativeFixture fixture, String id) async {
    final stats = await fixture.desktop.connection.request(
      'test/agent.stats',
      {},
    ) as Json;
    return ((stats['sessions'] as Json)[id] as Json)['hasGrant'] == true;
  }

  test('Codex: Codex receives its bridge configuration', () async {
    final (fixture, agent) = await start();
    expect(agent.started.tools?.status, AgentToolsStatus.notYetUsed);
    expect(await hasGrant(fixture, agent.id), isTrue);
    final methods = fixture.requests
        .map((request) => request['method'])
        .toList();
    expect(
      methods.indexOf('config/read'),
      greaterThan(methods.indexOf('initialize')),
    );
    expect(
      methods.indexOf('config/read'),
      lessThan(methods.indexOf('thread/start')),
    );
    final startRequest = fixture.requests.singleWhere(
      (request) => request['method'] == 'thread/start',
    );
    final config = (startRequest['params'] as Json)['config'] as Json;
    expect(config.keys.toList(), ['mcp_servers.kumiko']);
    final entry = config['mcp_servers.kumiko'] as Json;
    expect(entry['command'], testHostExecutable());
    expect(entry['args'], ['--mcp-bridge']);
    final env = entry['env'] as Json;
    expect(env['KUMIKO_TOOL_SECRET'] == '<redacted>', isTrue);
    expect(
      env.keys,
      containsAll([
        'KUMIKO_TOOL_ENDPOINT',
        'KUMIKO_TOOL_SECRET',
        'KUMIKO_UNIT',
      ]),
    );
    expect(
      fixture.reports
          .where((row) => row['launch'] != null)
          .every((row) => row['secret'] == false),
      isTrue,
    );
    await agent.close();
  });

  test(
    'Codex: native session_info names runtime and immutable root target',
    () async {
      final (fixture, agent) = await start(
        script: {
          'kumikoTool': {'when': 'prompt', 'call': 'kumiko_session_info'},
        },
      );
      expect(agent.started.tools?.status, AgentToolsStatus.notYetUsed);
      await agent.prompt();
      final result = await waitFixture(
        fixture.report,
        (row) => row.containsKey('kumikoToolResult'),
      );
      final info =
          ((result['kumikoToolResult'] as Json)['result']
                  as Json)['structuredContent']
              as Json;
      expect(info['sessionId'], agent.id);
      expect(info['runtime'], 'codex');
      expect(info['adapter'], {
        'name': 'codex-app-server',
        'version': '0.166.0',
      });
      expect(
        (info['target'] as Json)['path'],
        (agentRows(profile).single['target_path']),
      );
      await agent.wait(
        Method.agentState,
        where: (state) => (state['tools'] as Json?)?['status'] == 'connected',
      );
      await agent.close();
    },
  );

  test('Codex: Codex configuration cannot be applied', () async {
    final (fixture, agent) = await start(
      script: {
        'configReadError': {
          'code': -32601,
          'message': 'config/read unavailable',
        },
      },
    );
    expect(agent.started.tools?.status, AgentToolsStatus.unavailable);
    expect(agent.started.tools?.reason, contains('config/read'));
    expect(await hasGrant(fixture, agent.id), isFalse);
    final root = fixture.requests.singleWhere(
      (request) => request['method'] == 'thread/start',
    );
    expect((root['params'] as Json)['config'], isNull);
    await agent.prompt();
    await agent.wait(Method.agentTurnEnded);
    await agent.close();
  });

  test('Codex: User already defines kumiko MCP', () async {
    final (fixture, agent) = await start(
      script: {
        'configReadResult': {
          'config': <String, Object?>{},
          'origins': <String, Object?>{},
          'layers': [
            {
              'name': {'type': 'user', 'file': '/fixture/user.toml'},
              'version': 'fixture',
              'config': {
                'mcp_servers': {
                  'kumiko': {'command': 'user-owned'},
                },
              },
            },
          ],
        },
      },
    );
    expect(agent.started.tools?.status, AgentToolsStatus.unavailable);
    expect(
      agent.started.tools?.reason?.toLowerCase(),
      contains('already defines kumiko'),
    );
    expect(await hasGrant(fixture, agent.id), isFalse);
    final root = fixture.requests.singleWhere(
      (request) => request['method'] == 'thread/start',
    );
    expect((root['params'] as Json)['config'], isNull);
    await agent.close();
  });

  test('Codex: unavailable endpoint retains its actual reason', () async {
    final (fixture, agent) = await start(
      environment: {
        'KUMIKO_TEST_TOOL_ENDPOINT_FAULT': 'fixture endpoint unavailable',
      },
    );
    expect(agent.started.tools?.status, AgentToolsStatus.unavailable);
    expect(
      agent.started.tools?.reason,
      'endpoint-unavailable: fixture endpoint unavailable',
    );
    expect(await hasGrant(fixture, agent.id), isFalse);
    expect(
      fixture.requests.any((request) => request['method'] == 'config/read'),
      isFalse,
    );
    await agent.close();
  });

  test('Codex: Unrelated commands cannot read bridge secret', () async {
    final (fixture, agent) = await start(
      script: {
        'kumikoTool': {'when': 'prompt', 'call': 'kumiko_session_info'},
        'toolsAudit': {
          'scanRoots': [work.path, profile.path],
          'otherEnv': {'UNRELATED_MCP_MARKER': 'own-entry'},
        },
      },
    );
    await agent.prompt();
    await waitFixture(
      fixture.report,
      (row) => row.containsKey('kumikoToolResult'),
    );
    final audit = await waitFixture(
      fixture.report,
      (row) => row['toolsAudit'] == true,
    );
    for (final key in [
      'bridgeEntryHasSecret',
      'parentEnvironmentIsolated',
      'commandEnvironmentIsolated',
      'otherMcpEnvironmentIsolated',
      'scanComplete',
    ]) {
      expect(
        audit[key],
        true,
        reason: key == 'scanComplete' ? '$key ${audit['scanErrors']}' : key,
      );
    }
    expect(audit['secretFound'], false);
    expect(audit['errorCount'], 0);
    expect(audit['scannedFiles'] as int, greaterThan(0));
    await agent.close();
  });

  for (final leak in [false, true]) {
    test('Codex: post-run file canary detects leak=$leak', () async {
      final (fixture, agent) = await start(
        script: {
          'persistSecretForScanTest': leak,
          'toolsAudit': {
            'scanRoots': [work.path, profile.path],
          },
        },
      );
      await agent.prompt();
      await agent.wait(Method.agentTurnEnded);
      await agent.close();
      final stats = await fixture.desktop.connection.request(
        'test/agent.stats',
        {
          'secretScanSessionId': agent.id,
          'secretScanRoots': [work.path, profile.path],
        },
      ) as Json;
      final scan = stats['secretAudit'] as Json?;
      expect(
        scan,
        isNotNull,
        reason: 'post-settlement scan must not be omitted',
      );
      expect(scan!['complete'], true);
      expect(scan['errorCount'], 0);
      expect(scan['scannedFiles'] as int, greaterThan(0));
      expect((scan['matchedFiles'] as int) > 0, leak);
      expect((await toolState(fixture.desktop))['authenticated'], 0);
    });
  }

  test('Codex: Child bridge connection cap', () async {
    final (fixture, agent) = await start(
      script: {
        'kumikoPeers': [
          for (var i = 0; i < 5; i++) {'when': 'session/new', 'list': true},
        ],
      },
    );
    await waitFixture(
      fixture.report,
      (row) => row['peerIndex'] == 4 && row.containsKey('kumikoBridgeExit'),
    );
    expect((await toolState(fixture.desktop))['authenticated'], 4);
    await eventually(
      () => agent.events.toString().contains('child tools unavailable'),
      within: const Duration(seconds: 3),
      reason: 'refused child bridge must remain visible at the root',
    );
    expect(agent.of(Method.agentState).last['tools'], {'status': 'notYetUsed'});
    fixture.scriptFile.writeAsStringSync(
      jsonEncode({'reportFile': fixture.report.path}),
    );
    final other = AgentPeer(fixture.desktop);
    await other.start(fixture.workspace, runtime: 'native');
    await other.attach();
    expect(other.started.tools?.status, AgentToolsStatus.notYetUsed);
    expect(other.events.toString().contains('child tools unavailable'), false);
    await other.close();
    expect((await toolState(fixture.desktop))['authenticated'], 4);
    await agent.close();
    expect((await toolState(fixture.desktop))['authenticated'], 0);
  });

  test('Codex: Child uses inherited Kumiko tools', () async {
    final other = tempDir('codex_child_other_');
    addTearDown(() => deleteTree(other));
    final (fixture, agent) = await start(
      script: {
        'kumikoPeers': [
          {'when': 'prompt', 'call': 'kumiko_session_info'},
        ],
      },
    );
    await fixture.desktop.openWorkspace(other.path);
    await agent.prompt();
    final result = await waitFixture(
      fixture.report,
      (row) => row['peerIndex'] == 0 && row.containsKey('kumikoToolResult'),
    );
    final info =
        ((result['kumikoToolResult'] as Json)['result']
                as Json)['structuredContent']
            as Json;
    expect(info['sessionId'], agent.id);
    expect(info['role'], 'coding');
    expect(info['runtime'], 'codex');
    expect(
      (info['target'] as Json)['path'],
      agentRows(profile).single['target_path'],
    );
    expect((info['target'] as Json)['path'] == other.path, false);
    await agent.close();
  });

  test('Codex: post-run scan refuses unreadable nonempty data', () async {
    if (!Platform.isWindows) {
      markTestSkipped('Windows mandatory file range lock');
      return;
    }
    final (fixture, agent) = await start();
    await agent.close();
    final file = File(p.join(work.path, 'locked-scan-control.bin'));
    file.writeAsStringSync('nonempty scanner control');
    final lock = file.openSync(mode: FileMode.append);
    lock.lockSync(FileLock.exclusive);
    try {
      final stats =
          await fixture.desktop.connection
                  .request('test/agent.stats', {
                    'secretScanSessionId': agent.id,
                    'secretScanRoots': [work.path, profile.path],
                  })
                  .timeout(const Duration(seconds: 5))
              as Json;
      final scan = stats['secretAudit'] as Json;
      expect(scan['complete'], false);
      expect(scan['errorCount'] as int, greaterThan(0));
    } finally {
      lock.unlockSync();
      lock.closeSync();
    }
  });

  for (final fails in [false, true]) {
    test(
      'Codex: Continue binds a fresh bridge after native history failure=$fails',
      () async {
        final (fixture, original) = await start();
        final savedId = original.id;
        final record = agentRows(profile).single;
        await original.close();
        await original.call(Method.agentRelease);
        expect((await toolState(fixture.desktop))['authenticated'], 0);
        final release = File(p.join(work.path, 'release-native-resume'));
        fixture.scriptFile.writeAsStringSync(
          jsonEncode({
            'reportFile': fixture.report.path,
            'version': 'codex-cli 0.167.0',
            if (fails)
              'startError': {
                'code': -32000,
                'message': 'fixture refused resume',
              },
            'kumikoTool': {
              'when': 'session/new',
              'call': 'kumiko_session_info',
            },
            'resumeActions': [
              {'waitFile': release.path},
            ],
            'readThread': {
              'id': 'root-thread',
              'historyMode': 'legacy',
              'status': {'type': 'notLoaded'},
            },
            'afterReadThread': {
              'id': 'root-thread',
              'historyMode': 'legacy',
              'status': {'type': 'idle'},
            },
            'resumeThread': {
              'id': 'root-thread',
              'historyMode': 'legacy',
              'status': {'type': 'idle'},
              'turns': [
                {
                  'id': 'old-turn',
                  'status': 'completed',
                  'items': [
                    {
                      'id': 'old-message',
                      'type': 'agentMessage',
                      'text': 'saved answer',
                    },
                  ],
                },
              ],
            },
          }),
        );
        fixture.report.writeAsStringSync('');
        final agent = AgentPeer(fixture.desktop);
        final result = AgentContinueResult.fromJson(
          await agent.call(Method.agentContinue, {'sessionId': savedId}),
        );
        agent.started = AgentStartResult(
          sessionId: savedId,
          eventChannel: result.eventChannel,
          adapter: result.adapter,
          capabilities: result.capabilities,
          tools: result.tools,
        );
        await agent.attach();
        await waitFixture(
          fixture.report,
          (row) => row.containsKey('kumikoToolListed'),
        );
        await eventually(
          () async =>
              (await toolState(fixture.desktop))['pendingBindings'] == 1,
        );
        expect(
          fixture.reports.any((row) => row.containsKey('kumikoToolResult')),
          false,
        );
        release.writeAsStringSync('continue');
        if (fails) {
          final exit = await agent.wait(Method.agentExited);
          expect(exit['error'], ErrorCode.resumeUnavailable);
          expect(agentRows(profile).single, record);
          expect((await toolState(fixture.desktop))['authenticated'], 0);
          expect((await toolState(fixture.desktop))['pendingBindings'], 0);
          expect(
            fixture.requests.where(
              (request) => request['method'] == 'thread/resume',
            ),
            hasLength(1),
          );
          expect(
            fixture.requests.where(
              (request) =>
                  request['method'] == 'thread/start' ||
                  request['method'] == 'turn/start',
            ),
            isEmpty,
          );
          expect(
            fixture.reports
                .where((row) => row.containsKey('kumikoToolResult'))
                .every(
                  (row) => (row['kumikoToolResult'] as Json)['result'] == null,
                ),
            true,
          );
          return;
        }
        final response = await waitFixture(
          fixture.report,
          (row) => row.containsKey('kumikoToolResult'),
        );
        final info =
            ((response['kumikoToolResult'] as Json)['result']
                    as Json)['structuredContent']
                as Json;
        expect(info['sessionId'], savedId);
        expect(info['runtime'], 'codex');
        expect(info['adapter'], {
          'name': 'codex-app-server',
          'version': '0.167.0',
        });
        expect((info['target'] as Json)['path'], record['target_path']);
        expect(agentRows(profile).single, record);
        final resumed = fixture.requests.singleWhere(
          (request) => request['method'] == 'thread/resume',
        );
        expect(
          ((resumed['params'] as Json)['config'] as Json).containsKey(
            'mcp_servers.kumiko',
          ),
          true,
        );
        expect(
          fixture.requests.where(
            (request) => request['method'] == 'turn/start',
          ),
          isEmpty,
        );
        await agent.close();
        expect((await toolState(fixture.desktop))['authenticated'], 0);
      },
    );
  }

  for (final fails in [false, true]) {
    test('Codex: pending native binding settles failure=$fails', () async {
      final release = File(p.join(work.path, 'release-native-start'));
      final fixture = NativeFixture(
        profile,
        work,
        script: {
          'kumikoTool': {'when': 'session/new', 'call': 'kumiko_session_info'},
          'newActions': [
            {'waitFile': release.path},
          ],
          if (fails)
            'startError': {'code': -32000, 'message': 'fixture refused thread'},
        },
      );
      await fixture.open();
      final agent = AgentPeer(fixture.desktop);
      final starting = agent.start(fixture.workspace, runtime: 'native');
      final observedStart = starting.then<Object?>(
        (value) => value,
        onError: (Object error) => error,
      );
      await waitFixture(
        fixture.report,
        (row) => row.containsKey('kumikoToolListed'),
      );
      final state = await toolState(fixture.desktop);
      expect(state.containsKey('pendingBindings'), true);
      await eventually(
        () async => (await toolState(fixture.desktop))['pendingBindings'] == 1,
      );
      expect(
        fixture.reports.any((row) => row.containsKey('kumikoToolResult')),
        false,
      );
      release.writeAsStringSync('continue');
      final outcome = await observedStart;
      if (fails) {
        expect(outcome, isA<RpcException>());
        expect((await toolState(fixture.desktop))['pendingBindings'], 0);
        expect(agentRows(profile), isEmpty);
        expect(
          fixture.requests.where(
            (request) => request['method'] == 'thread/start',
          ),
          hasLength(1),
        );
        // Revocation is immediate; the physical connection slot is released
        // only once its transport has finished closing.
        await eventually(
          () async => (await toolState(fixture.desktop))['authenticated'] == 0,
        );
        expect((await toolState(fixture.desktop))['authenticated'], 0);
      } else {
        expect(outcome, isA<AgentStartResult>());
        final result = await waitFixture(
          fixture.report,
          (row) => row.containsKey('kumikoToolResult'),
        );
        final info =
            ((result['kumikoToolResult'] as Json)['result']
                    as Json)['structuredContent']
                as Json;
        expect(info['sessionId'], agent.id);
        await agent.attach();
        await agent.close();
      }
    });
  }
}
