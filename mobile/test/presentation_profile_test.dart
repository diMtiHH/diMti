import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/presentation_profile.dart';

class MemoryPresentationBackend implements PresentationBackend {
  String? value;
  Object? readError, writeError;
  bool commitBeforeWriteError = false;
  Completer<void>? readGate, writeGate;
  int reads = 0, activeWrites = 0, maxActiveWrites = 0;
  final writes = <String>[];

  @override
  Future<String?> readProfile() async {
    ++reads;
    final gate = readGate;
    if (gate != null) await gate.future;
    if (readError != null) throw readError!;
    return value;
  }

  @override
  Future<void> writeProfile(String next) async {
    writes.add(next);
    ++activeWrites;
    if (activeWrites > maxActiveWrites) maxActiveWrites = activeWrites;
    try {
      final gate = writeGate;
      if (gate != null) await gate.future;
      if (commitBeforeWriteError) value = next;
      if (writeError != null) throw writeError!;
      value = next;
    } finally {
      --activeWrites;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, Object?> defaultsMap() => Map<String, Object?>.from(
    jsonDecode(const PresentationProfile.defaults().toJson()) as Map,
  );

  Map<String, Object?> legacyMap({
    String background = 'nebula',
    String style = 'coin',
  }) => {
    'version': 1,
    'name': '  Старое имя 🌟  ',
    'background': background,
    'answerStyle': style,
    'onboardingStep': 2,
    'completed': true,
    'termsVersion': currentTermsVersion,
    'audioEnabled': false,
  };

  Future<void> flush() async {
    // Let queued persistence enter its fake backend without completing gates.
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'only absent storage produces defaults, without writing or consent',
    () async {
      final backend = MemoryPresentationBackend();
      final controller = PresentationController(backend);
      addTearDown(controller.dispose);
      expect(controller.profile, isNull);
      final loading = controller.load();
      expect(controller.busy, isTrue);
      expect(await loading, isTrue);
      expect(controller.profile, const PresentationProfile.defaults());
      expect(controller.profile!.name, isEmpty);
      expect(controller.profileWasMissing, isTrue);
      expect(controller.profile!.version, 2);
      expect(controller.profile!.background, PresentationBackground.aurora);
      expect(
        controller.profile!.answerStyle,
        PresentationAnswerStyle.livingMatter,
      );
      expect(controller.profile!.audioEnabled, isTrue);
      expect(controller.profile!.ambientEnabled, isFalse);
      expect(controller.profile!.hapticsEnabled, isTrue);
      expect(controller.profile!.onboardingStep, 0);
      expect(controller.needsOnboarding, isTrue);
      expect(controller.needsConsent, isTrue);
      expect(controller.busy, isFalse);
      expect(controller.failed, isFalse);
      expect(backend.writes, isEmpty);
    },
  );

  for (final background in PresentationBackground.values) {
    for (final answerStyle in PresentationAnswerStyle.values) {
      test(
        '${background.name}/${answerStyle.name} survives persistence and restart',
        () async {
          final backend = MemoryPresentationBackend();
          final first = PresentationController(backend);
          await first.load();
          final selected = first.profile!.copyWith(
            name: 'Вселенная 🌟',
            background: background,
            answerStyle: answerStyle,
            onboardingStep: 2,
            audioEnabled: false,
            ambientEnabled: true,
            hapticsEnabled: false,
          );
          expect(await first.save(selected), isTrue);
          expect(first.profileWasMissing, isFalse);
          first.dispose();
          final restarted = PresentationController(backend);
          addTearDown(restarted.dispose);
          expect(await restarted.load(), isTrue);
          expect(restarted.profile, selected);
          expect(restarted.profile!.background, background);
          expect(restarted.profile!.answerStyle, answerStyle);
          expect(restarted.profileWasMissing, isFalse);
          expect(restarted.needsOnboarding, isTrue);
          expect(restarted.needsConsent, isTrue);
          expect(backend.writes, hasLength(1));
        },
      );
    }
  }

  const legacyBackgrounds = {
    'stars': PresentationBackground.stars,
    'galaxy': PresentationBackground.galaxy,
    'nebula': PresentationBackground.aurora,
    'blackHole': PresentationBackground.gravity,
  };
  const legacyStyles = {
    'coin': PresentationAnswerStyle.livingMatter,
    'sphere': PresentationAnswerStyle.liquidMetal,
    'blackHole': PresentationAnswerStyle.infinity,
    'constellation': PresentationAnswerStyle.constellation,
  };
  for (final background in legacyBackgrounds.entries) {
    for (final style in legacyStyles.entries) {
      test(
        'v1 ${background.key}/${style.key} migrates without rewriting storage',
        () async {
          final original = jsonEncode(
            legacyMap(background: background.key, style: style.key),
          );
          final backend = MemoryPresentationBackend()..value = original;
          final controller = PresentationController(backend);
          addTearDown(controller.dispose);
          expect(await controller.load(), isTrue);
          final profile = controller.profile!;
          expect(controller.profileWasMissing, isFalse);
          expect(profile.version, 2);
          expect(profile.background, background.value);
          expect(profile.answerStyle, style.value);
          expect(profile.name, '  Старое имя 🌟  ');
          expect(profile.completed, isTrue);
          expect(profile.onboardingStep, 2);
          expect(profile.termsVersion, currentTermsVersion);
          expect(profile.audioEnabled, isFalse);
          expect(profile.ambientEnabled, isFalse);
          expect(profile.hapticsEnabled, isTrue);
          expect(controller.needsConsent, isFalse);
          expect(backend.value, original);
          expect(backend.writes, isEmpty);
          expect(await controller.load(), isTrue);
          expect(backend.value, original);
          expect(backend.writes, isEmpty);
          expect(
            await controller.save(profile.copyWith(ambientEnabled: true)),
            isTrue,
          );
          final committed = jsonDecode(backend.value!) as Map;
          expect(committed['version'], 2);
          expect(
            committed.keys,
            unorderedEquals([
              'version',
              'name',
              'background',
              'answerStyle',
              'onboardingStep',
              'completed',
              'termsVersion',
              'audioEnabled',
              'ambientEnabled',
              'hapticsEnabled',
            ]),
          );
          expect(await controller.load(), isTrue);
          expect(controller.profile, profile.copyWith(ambientEnabled: true));
        },
      );
    }
  }

  test('v1 narration and incomplete onboarding survive migration independently of ambience', () {
    for (final enabled in [false, true]) {
      for (final step in [0, 1, 2]) {
        final migrated = PresentationProfile.fromJson(
          jsonEncode({
            ...legacyMap(),
            'completed': false,
            'termsVersion': 0,
            'onboardingStep': step,
            'audioEnabled': enabled,
          }),
        );
        expect(migrated.audioEnabled, enabled);
        expect(migrated.ambientEnabled, isFalse);
        expect(migrated.hapticsEnabled, isTrue);
        expect(migrated.onboardingStep, step);
        expect(migrated.needsOnboarding, isTrue);
        expect(migrated.termsVersion, 0);
      }
    }
  });

  test('v1 migration rejects mixed schemas corruption and unknown options without a write', () async {
    final valid = jsonEncode(legacyMap());
    final invalid = [
      jsonEncode({...legacyMap()}..remove('name')),
      jsonEncode({...legacyMap(), 'ambientEnabled': false}),
      jsonEncode({...legacyMap(), 'hapticsEnabled': true}),
      jsonEncode({...legacyMap(), 'version': 2}),
      jsonEncode({...legacyMap(), 'version': 3}),
      jsonEncode({...legacyMap(), 'background': 'aurora'}),
      jsonEncode({...legacyMap(), 'answerStyle': 'livingMatter'}),
      jsonEncode({...legacyMap(), 'background': 'unknown'}),
      jsonEncode({...legacyMap(), 'audioEnabled': 1}),
      jsonEncode({...legacyMap(), 'name': 'line\ncontrol'}),
      jsonEncode({...legacyMap(), 'completed': false}),
      valid.replaceFirst('"version":1', r'"version":1,"\u0076ersion":1'),
      valid.replaceFirst('"version":1', '"version":1.0'),
    ];
    for (final raw in invalid) {
      final backend = MemoryPresentationBackend()..value = raw;
      final controller = PresentationController(backend);
      expect(await controller.load(), isFalse);
      expect(controller.profile, isNull);
      expect(controller.profileWasMissing, isFalse);
      expect(
        await controller.save(const PresentationProfile.defaults()),
        isFalse,
      );
      expect(backend.value, raw);
      expect(backend.writes, isEmpty);
      controller.dispose();
    }
  });

  for (final committed in [false, true]) {
    test(
      'first v2 write after migration committed=$committed needs explicit readback on error',
      () async {
        final legacy = jsonEncode(legacyMap());
        final backend = MemoryPresentationBackend()..value = legacy;
        final controller = PresentationController(backend);
        addTearDown(controller.dispose);
        await controller.load();
        final old = controller.profile!;
        final next = old.copyWith(hapticsEnabled: false, ambientEnabled: true);
        backend.writeError = PlatformException(code: 'storage_unavailable');
        backend.commitBeforeWriteError = committed;
        expect(await controller.save(next), isFalse);
        expect(controller.profile, old);
        expect(controller.failed, isTrue);
        expect(await controller.acceptTerms(), isFalse);
        expect(backend.writes, hasLength(1));
        expect(backend.value, committed ? next.toJson() : legacy);
        backend.writeError = null;
        expect(await controller.load(), isTrue);
        expect(controller.profile, committed ? next : old);
        expect(backend.writes, hasLength(1));
        expect(await controller.save(next), isTrue);
        expect(jsonDecode(backend.value!)['version'], 2);
      },
    );
  }

  test(
    'missing profile flag requires a successful read or acknowledged write',
    () async {
      final backend = MemoryPresentationBackend()
        ..readError = StateError('read unavailable');
      final controller = PresentationController(backend);
      addTearDown(controller.dispose);
      expect(controller.profileWasMissing, isFalse);
      expect(await controller.load(), isFalse);
      expect(controller.profileWasMissing, isFalse);
      backend.readError = null;
      expect(await controller.load(), isTrue);
      expect(controller.profileWasMissing, isTrue);
      backend.writeGate = Completer<void>();
      final saving = controller.save(
        controller.profile!.copyWith(name: 'Saved'),
      );
      await flush();
      expect(controller.profileWasMissing, isTrue);
      backend.writeGate!.complete();
      expect(await saving, isTrue);
      expect(controller.profileWasMissing, isFalse);
    },
  );

  test(
    'name clearing preserves independent presentation choices and consent',
    () async {
      final original = PresentationProfile(
        name: 'Имя',
        background: PresentationBackground.aurora,
        answerStyle: PresentationAnswerStyle.livingMatter,
        onboardingStep: 2,
        completed: true,
        termsVersion: currentTermsVersion,
        audioEnabled: false,
        ambientEnabled: true,
        hapticsEnabled: false,
      );
      final backend = MemoryPresentationBackend()..value = original.toJson();
      final controller = PresentationController(backend);
      addTearDown(controller.dispose);
      await controller.load();
      final cleared = controller.profile!.copyWith(name: '');
      expect(await controller.save(cleared), isTrue);
      expect(await controller.load(), isTrue);
      expect(controller.profile, original.copyWith(name: ''));
      expect(controller.needsOnboarding, isFalse);
      expect(controller.needsConsent, isFalse);
      final renamed = cleared.copyWith(name: '  Новое имя  ');
      expect(renamed.name, '  Новое имя  ');
      expect(renamed.background, original.background);
      expect(renamed.answerStyle, original.answerStyle);
      expect(renamed.audioEnabled, isFalse);
      expect(renamed.ambientEnabled, isTrue);
      expect(renamed.hapticsEnabled, isFalse);
    },
  );

  for (final step in [0, 1, 2]) {
    test(
      'unfinished onboarding resumes step $step without accepting terms',
      () async {
        final backend = MemoryPresentationBackend();
        final first = PresentationController(backend);
        await first.load();
        await first.save(first.profile!.copyWith(onboardingStep: step));
        first.dispose();
        final next = PresentationController(backend);
        addTearDown(next.dispose);
        await next.load();
        expect(next.profile!.onboardingStep, step);
        expect(next.profile!.termsVersion, 0);
        expect(next.profile!.completed, isFalse);
        expect(next.needsOnboarding, isTrue);
      },
    );
  }

  test(
    'consent persists completion, final step and version atomically',
    () async {
      final backend = MemoryPresentationBackend();
      final controller = PresentationController(backend);
      addTearDown(controller.dispose);
      await controller.load();
      final old = controller.profile!;
      backend.writeGate = Completer<void>();
      final accepting = controller.acceptTerms();
      await flush();
      expect(controller.busy, isTrue);
      expect(controller.profile, old);
      expect(controller.needsConsent, isTrue);
      final submitted = PresentationProfile.fromJson(backend.writes.single);
      expect(submitted.completed, isTrue);
      expect(submitted.onboardingStep, 2);
      expect(submitted.termsVersion, currentTermsVersion);
      backend.writeGate!.complete();
      expect(await accepting, isTrue);
      expect(controller.profile, submitted);
      expect(controller.needsOnboarding, isFalse);
      expect(controller.needsConsent, isFalse);
      expect(backend.writes, hasLength(1));
    },
  );

  test(
    'different accepted terms require only consent, preserving the profile',
    () async {
      final existing = PresentationProfile(
        name: 'Звезда',
        background: PresentationBackground.gravity,
        answerStyle: PresentationAnswerStyle.constellation,
        onboardingStep: 2,
        completed: true,
        termsVersion: currentTermsVersion + 1,
        audioEnabled: false,
      );
      final backend = MemoryPresentationBackend()..value = existing.toJson();
      final controller = PresentationController(backend);
      addTearDown(controller.dispose);
      expect(await controller.load(), isTrue);
      expect(controller.needsOnboarding, isFalse);
      expect(controller.needsConsent, isTrue);
      expect(backend.writes, isEmpty);
      expect(await controller.acceptTerms(), isTrue);
      expect(
        controller.profile,
        existing.copyWith(termsVersion: currentTermsVersion),
      );
    },
  );

  test(
    'writes and consent are serialized, never optimistically committed',
    () async {
      final backend = MemoryPresentationBackend();
      final controller = PresentationController(backend);
      addTearDown(controller.dispose);
      await controller.load();
      final old = controller.profile!;
      final renamed = old.copyWith(name: 'Последовательность');
      backend.writeGate = Completer<void>();
      final save = controller.save(renamed);
      final consent = controller.acceptTerms();
      await flush();
      expect(backend.writes, hasLength(1));
      expect(controller.profile, old);
      expect(controller.busy, isTrue);
      backend.writeGate!.complete();
      expect(await save, isTrue);
      expect(await consent, isTrue);
      expect(backend.maxActiveWrites, 1);
      expect(backend.writes, hasLength(2));
      expect(controller.profile!.name, renamed.name);
      expect(controller.profile!.completed, isTrue);
      expect(controller.busy, isFalse);
      expect(PresentationProfile.fromJson(backend.value!), controller.profile);
    },
  );

  test(
    'listener-enqueued mutation cannot overtake the initiating save',
    () async {
      final backend = MemoryPresentationBackend();
      final controller = PresentationController(backend);
      addTearDown(controller.dispose);
      await controller.load();
      Future<bool>? consent;
      var enqueued = false;
      controller.addListener(() {
        if (controller.busy && !enqueued) {
          enqueued = true;
          consent = controller.acceptTerms();
        }
      });
      expect(
        await controller.save(controller.profile!.copyWith(name: 'Первый')),
        isTrue,
      );
      expect(await consent, isTrue);
      expect(controller.profile!.name, 'Первый');
      expect(controller.profile!.completed, isTrue);
      expect(backend.writes, hasLength(2));
    },
  );

  for (final committed in [false, true]) {
    test(
      'ambiguous write committed=$committed blocks mutations until readback',
      () async {
        final backend = MemoryPresentationBackend();
        final controller = PresentationController(backend);
        addTearDown(controller.dispose);
        await controller.load();
        final old = controller.profile!;
        final attempted = old.copyWith(name: 'Неопределённая запись');
        backend.writeError = PlatformException(code: 'storage');
        backend.commitBeforeWriteError = committed;
        final saving = controller.save(attempted);
        final queuedConsent = controller.acceptTerms();
        expect(await saving, isFalse);
        expect(await queuedConsent, isFalse);
        expect(controller.failed, isTrue);
        expect(controller.profile, old);
        expect(controller.busy, isFalse);
        expect(
          await controller.save(old.copyWith(name: 'Не перезаписывать')),
          isFalse,
        );
        expect(backend.writes, hasLength(1));
        backend.writeError = null;
        expect(await controller.load(), isTrue);
        expect(controller.profile, committed ? attempted : old);
        expect(controller.failed, isFalse);
        expect(await controller.acceptTerms(), isTrue);
        expect(controller.profile!.name, committed ? attempted.name : old.name);
      },
    );
  }

  test(
    'read corruption blocks first load and does not rewrite defaults',
    () async {
      final backend = MemoryPresentationBackend()..value = '{broken';
      final controller = PresentationController(backend);
      addTearDown(controller.dispose);
      expect(await controller.load(), isFalse);
      expect(controller.profile, isNull);
      expect(controller.failed, isTrue);
      expect(
        await controller.save(const PresentationProfile.defaults()),
        isFalse,
      );
      expect(await controller.acceptTerms(), isFalse);
      expect(backend.value, '{broken');
      expect(backend.writes, isEmpty);
    },
  );

  test(
    'failed reload retains last profile but blocks writes until valid read',
    () async {
      final original = PresentationProfile(name: 'Последнее достоверное');
      final backend = MemoryPresentationBackend()..value = original.toJson();
      final controller = PresentationController(backend);
      addTearDown(controller.dispose);
      await controller.load();
      backend.value = '{}';
      expect(await controller.load(), isFalse);
      expect(controller.profile, original);
      expect(controller.failed, isTrue);
      expect(
        await controller.save(original.copyWith(name: 'Не записывать')),
        isFalse,
      );
      expect(backend.writes, isEmpty);
      backend.value = original.copyWith(name: 'Восстановлено').toJson();
      expect(await controller.load(), isTrue);
      expect(controller.profile!.name, 'Восстановлено');
      expect(controller.failed, isFalse);
    },
  );

  test(
    'missing native plugin is a storage failure, not an absent profile',
    () async {
      final backend = MemoryPresentationBackend()
        ..readError = MissingPluginException();
      final controller = PresentationController(backend);
      addTearDown(controller.dispose);
      expect(await controller.load(), isFalse);
      expect(controller.profile, isNull);
      expect(controller.failed, isTrue);
      expect(backend.writes, isEmpty);
      backend.readError = null;
      expect(await controller.load(), isTrue);
      expect(controller.profile, const PresentationProfile.defaults());
    },
  );

  test(
    'load flags reflect a delayed read and saves wait for that read',
    () async {
      final backend = MemoryPresentationBackend()..readGate = Completer<void>();
      final controller = PresentationController(backend);
      addTearDown(controller.dispose);
      final reading = controller.load();
      final saving = controller.save(PresentationProfile(name: 'После чтения'));
      await flush();
      expect(controller.loading, isTrue);
      expect(controller.busy, isTrue);
      expect(controller.profile, isNull);
      expect(backend.writes, isEmpty);
      backend.readGate!.complete();
      expect(await reading, isTrue);
      expect(await saving, isTrue);
      expect(controller.loading, isFalse);
      expect(controller.busy, isFalse);
      expect(controller.profile!.name, 'После чтения');
    },
  );

  test('dispose prevents late publication and skips queued writes', () async {
    final backend = MemoryPresentationBackend();
    final controller = PresentationController(backend);
    await controller.load();
    final old = controller.profile!;
    var notifications = 0;
    controller.addListener(() => ++notifications);
    backend.writeGate = Completer<void>();
    final saving = controller.save(old.copyWith(name: 'Может сохраниться'));
    final queued = controller.acceptTerms();
    await flush();
    controller.dispose();
    final countAtDispose = notifications;
    backend.writeGate!.complete();
    expect(await saving, isFalse);
    expect(await queued, isFalse);
    expect(controller.profile, old);
    expect(notifications, countAtDispose);
    expect(backend.writes, hasLength(1));
    expect(await controller.load(), isFalse);
    expect(await controller.save(old), isFalse);
    final restored = PresentationController(backend);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.profile!.name, 'Может сохраниться');
  });

  test('a late read after dispose does not publish a profile', () async {
    final backend = MemoryPresentationBackend()..readGate = Completer<void>();
    final controller = PresentationController(backend);
    final reading = controller.load();
    await flush();
    controller.dispose();
    backend.readGate!.complete();
    expect(await reading, isFalse);
    expect(controller.profile, isNull);
  });

  test('names use Unicode scalars, preserve spacing and reject C0/C1', () {
    expect(PresentationProfile.isValidName(''), isTrue);
    final emoji40 = List.filled(40, '🌟').join();
    expect(PresentationProfile(name: emoji40).name, emoji40);
    expect(PresentationProfile.isValidName('$emoji40🌟'), isFalse);
    expect(
      PresentationProfile.isValidName(List.filled(20, 'e\u0301').join()),
      isTrue,
    );
    expect(
      PresentationProfile.isValidName(List.filled(21, 'e\u0301').join()),
      isFalse,
    );
    expect(PresentationProfile(name: '  Имя  ').name, '  Имя  ');
    for (final scalar in [
      ...List.generate(32, (index) => index),
      ...List.generate(33, (index) => 0x7f + index),
      0xd800,
      0xdfff,
    ]) {
      expect(
        PresentationProfile.isValidName('a${String.fromCharCode(scalar)}'),
        isFalse,
      );
    }
    expect(PresentationProfile.isValidName('🌌\u200d🌟'), isTrue);
  });

  test('schema rejects missing, extra, mistyped, unknown and inconsistent values', () {
    final invalid = <Map<String, Object?>>[
      {...defaultsMap()}..remove('name'),
      {...defaultsMap(), 'question': 'must not be stored'},
      {...defaultsMap(), 'version': 3},
      {...defaultsMap(), 'version': 1},
      {...defaultsMap(), 'version': 1.0},
      {...defaultsMap(), 'version': true},
      {...defaultsMap(), 'name': null},
      {...defaultsMap(), 'name': List.filled(41, 'a').join()},
      {...defaultsMap(), 'name': 'line\nbreak'},
      {...defaultsMap(), 'background': 'unknown'},
      {...defaultsMap(), 'answerStyle': 'unknown'},
      {...defaultsMap(), 'background': 'nebula'},
      {...defaultsMap(), 'background': 'blackHole'},
      {...defaultsMap(), 'answerStyle': 'sphere'},
      {...defaultsMap(), 'answerStyle': 'coin'},
      {...defaultsMap(), 'answerStyle': 'blackHole'},
      {...defaultsMap(), 'onboardingStep': -1},
      {...defaultsMap(), 'onboardingStep': 3},
      {...defaultsMap(), 'onboardingStep': 0.0},
      {...defaultsMap(), 'completed': 0},
      {...defaultsMap(), 'termsVersion': -1},
      {...defaultsMap(), 'termsVersion': 100001},
      {...defaultsMap(), 'termsVersion': 0.0},
      {...defaultsMap(), 'audioEnabled': 'true'},
      {...defaultsMap()}..remove('ambientEnabled'),
      {...defaultsMap()}..remove('hapticsEnabled'),
      {...defaultsMap(), 'ambientEnabled': 1},
      {...defaultsMap(), 'hapticsEnabled': 'false'},
      {...defaultsMap(), 'termsVersion': 1},
      {...defaultsMap(), 'completed': true, 'onboardingStep': 2},
      {...defaultsMap(), 'completed': true, 'termsVersion': 1},
    ];
    for (final value in invalid) {
      expect(
        () => PresentationProfile.fromJson(jsonEncode(value)),
        throwsFormatException,
      );
    }
    for (final raw in [
      '',
      'null',
      '[]',
      '"profile"',
      '{',
      const PresentationProfile.defaults().toJson().replaceFirst(
        '"version":2',
        '"version":2e0',
      ),
      '${List.filled(maxPresentationProfileBytes, ' ').join()}${const PresentationProfile.defaults().toJson()}',
    ]) {
      expect(() => PresentationProfile.fromJson(raw), throwsFormatException);
    }
    final largestVersion = PresentationProfile(
      completed: true,
      onboardingStep: 2,
      termsVersion: 100000,
    );
    expect(
      PresentationProfile.fromJson(largestVersion.toJson()),
      largestVersion,
    );
    expect(
      () => largestVersion.copyWith(completed: false),
      throwsFormatException,
    );
    expect(
      () => const PresentationProfile.defaults().copyWith(termsVersion: 1),
      throwsFormatException,
    );
  });

  test('duplicate fields including escaped spellings are corruption', () async {
    final completed = PresentationProfile(
      name: '"completed": false, \\ {}',
      completed: true,
      onboardingStep: 2,
      termsVersion: currentTermsVersion,
    );
    final valid = completed.toJson();
    expect(PresentationProfile.fromJson(valid), completed);
    final duplicates = [
      valid.replaceFirst(
        '"completed":true',
        '"completed":false,"completed":true',
      ),
      valid.replaceFirst(
        '"termsVersion":1',
        r'"termsVersion":0,"terms\u0056ersion":1',
      ),
      valid.replaceFirst('"name":', '"name":"old", "name":'),
    ];
    for (final raw in duplicates) {
      expect(() => PresentationProfile.fromJson(raw), throwsFormatException);
      final backend = MemoryPresentationBackend()..value = raw;
      final controller = PresentationController(backend);
      expect(await controller.load(), isFalse);
      expect(controller.failed, isTrue);
      expect(controller.profile, isNull);
      expect(await controller.acceptTerms(), isFalse);
      expect(backend.writes, isEmpty);
      controller.dispose();
    }
  });

  test(
    'native backend uses only the profile channel and exact payload',
    () async {
      const channel = IosPresentationBackend.channel;
      final calls = <MethodCall>[];
      String? stored;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'readProfile') return stored;
            if (call.method == 'writeProfile') {
              final args = call.arguments as Map;
              expect(args.keys, ['value']);
              stored = args['value'] as String;
              return null;
            }
            throw MissingPluginException();
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      const backend = IosPresentationBackend();
      expect(await backend.readProfile(), isNull);
      final value = PresentationProfile(name: 'Канал').toJson();
      await backend.writeProfile(value);
      expect(await backend.readProfile(), value);
      expect(calls.map((call) => call.method), [
        'readProfile',
        'writeProfile',
        'readProfile',
      ]);
      expect(calls.first.arguments, isNull);
    },
  );
}
