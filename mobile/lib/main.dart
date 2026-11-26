import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'engine.dart';
import 'device_run.dart';
import 'device_report.dart';
import 'worker.dart';
import 'session_page.dart';

void main() => runApp(const UniverseApp());

class UniverseLab extends StatelessWidget {
  const UniverseLab({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Спроси Вселенную',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff86a7df),
        brightness: Brightness.dark,
      ),
    ),
    home: const LabPage(),
  );
}

class LabPage extends StatefulWidget {
  final Directory? modelDirectory;
  const LabPage({super.key, this.modelDirectory});
  @override
  State<LabPage> createState() => _LabPageState();
}

class _LabPageState extends State<LabPage> with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _worker = ModelWorker();
  bool _ru = true, _loading = true, _failed = false, _running = false;
  Reading? _result;
  DeviceReport? _report;
  int _generation = 0;
  String t(String ru, String en) => _ru ? ru : en;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    try {
      // Release iOS Runner bundles flutter_assets in App.framework.
      final app = File(Platform.resolvedExecutable).parent;
      await _worker.start(
        (widget.modelDirectory ??
                Directory.fromUri(
                  app.uri.resolve(
                    const bool.fromEnvironment('UNIVERSE_TEST_MISSING_MODEL')
                        ? 'Frameworks/App.framework/flutter_assets/missing-stage2/'
                        : 'Frameworks/App.framework/flutter_assets/assets/stage2/',
                  ),
                ))
            .path,
      );
    } catch (_) {
      _failed = true;
      _worker.close();
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      ++_generation;
      _input.clear();
      if (mounted) setState(() => _result = null);
    }
  }

  Future<void> _check() async {
    if (_running || _failed || _loading || _input.text.trim().isEmpty) return;
    final generation = _generation;
    setState(() {
      _running = true;
      _result = null;
      _report = null;
    });
    final request = _worker.inspect(_input.text, _ru ? 'ru' : 'en');
    _input.clear();
    final reading = await request;
    if (!mounted) return;
    setState(() {
      _running = false;
      _failed = !_worker.available;
      if (generation == _generation) _result = reading;
    });
  }

  Future<void> _benchmark() async {
    if (_running || _loading || _failed) return;
    final generation = _generation;
    _input.clear();
    setState(() {
      _running = true;
      _result = null;
      _report = null;
    });
    try {
      final result = await DeviceRun.measure(
        _worker.inspect,
        () => mounted && generation == _generation,
      );
      if (mounted && generation == _generation) {
        setState(
          () => _report = DeviceReport(
            measurement: result,
            measuredAt: DateTime.now(),
            loadMs: _worker.loadMs,
            operatingSystem: Platform.operatingSystem,
            operatingSystemVersion: Platform.operatingSystemVersion,
            buildMode: kReleaseMode
                ? 'release'
                : kProfileMode
                ? 'profile'
                : 'debug',
          ),
        );
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () => _result = const Reading(Outcome.error, 'benchmark_failed'),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _failed = !_worker.available;
        });
      }
    }
  }

  Future<void> _copyReport() async {
    final report = _report;
    if (report == null || _running) return;
    String message;
    try {
      await Clipboard.setData(ClipboardData(text: report.encode()));
      message = t('Отчёт скопирован', 'Report copied');
    } catch (_) {
      message = t(
        'Не удалось скопировать отчёт.',
        'Could not copy the report.',
      );
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  String _message(Reading result) {
    if (result.reason == 'input_too_long') {
      return t(
        'Текст слишком длинный для полной проверки.',
        'Text is too long to check in full.',
      );
    }
    return switch (result.outcome) {
      Outcome.error => t(
        'Проверка не выполнена.',
        'Could not complete the check.',
      ),
      Outcome.risk => t(
        'Модель отметила возможный риск.',
        'The model flagged possible risk.',
      ),
      Outcome.held => t(
        'Проверка завершена. Допуск закрыт.',
        'Check complete. Admission is closed.',
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !_loading && !_failed && !_running;
    final measurement = _report?.measurement;
    return Scaffold(
      appBar: AppBar(title: Text(t('Спроси Вселенную', 'Ask the Universe'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              t('Локальная проверка', 'Local validation'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              t(
                'Тест на устройстве. Допуск закрыт для всех вопросов.',
                'Device test. Admission is closed for every question.',
              ),
            ),
            const SizedBox(height: 20),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Русский')),
                ButtonSegment(value: false, label: Text('English')),
              ],
              selected: {_ru},
              onSelectionChanged: _running
                  ? null
                  : (values) => setState(() {
                      _ru = values.single;
                      _input.clear();
                      _result = null;
                    }),
            ),
            const SizedBox(height: 20),
            if (_loading) const LinearProgressIndicator(),
            Text(
              _loading
                  ? t('Проверка файлов модели…', 'Verifying model files…')
                  : _failed
                  ? t(
                      'Модель недоступна. Проверка заблокирована.',
                      'Model unavailable. Check blocked.',
                    )
                  : t('Модель готова', 'Model ready'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _input,
              enabled: enabled,
              minLines: 2,
              maxLines: 5,
              enableSuggestions: false,
              autocorrect: false,
              enableIMEPersonalizedLearning: false,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: t('Текст вопроса', 'Question text'),
              ),
            ),
            TextButton(
              onPressed: enabled
                  ? () {
                      _input.text = t(
                        'Стоит ли мне сегодня почитать роман?',
                        'Should I read a novel today?',
                      );
                    }
                  : null,
              child: Text(t('Вставить пример', 'Use sample')),
            ),
            FilledButton(
              onPressed: enabled ? _check : null,
              child: Text(
                _running
                    ? t('Проверяю…', 'Checking…')
                    : t('Проверить на устройстве', 'Check on device'),
              ),
            ),
            OutlinedButton(
              onPressed: enabled ? _benchmark : null,
              child: Text(t('Замер на 20 примерах', 'Measure 20 checks')),
            ),
            if (measurement case final m?) ...[
              Semantics(
                liveRegion: true,
                child: Text(
                  t(
                    'Проверок: ${m.checked} · p50: ${m.p50Ms} мс · p95: ${m.p95Ms} мс · макс. замер памяти: ${m.maxSampledRssMiB} МиБ',
                    'Checks: ${m.checked} · p50: ${m.p50Ms} ms · p95: ${m.p95Ms} ms · max sampled memory: ${m.maxSampledRssMiB} MiB',
                  ),
                ),
              ),
              Text(
                t(
                  'Отчёт содержит только технические замеры. Текст вопросов не включается.',
                  'The report contains technical measurements only. Question text is not included.',
                ),
              ),
              TextButton(
                onPressed: enabled ? _copyReport : null,
                child: Text(t('Копировать отчёт', 'Copy report')),
              ),
            ],
            if (_result case final reading?) ...[
              const SizedBox(height: 16),
              Semantics(liveRegion: true, child: Text(_message(reading))),
              if (reading.rssBytes > 0)
                Text(
                  t(
                    'Загрузка: ${_worker.loadMs} мс · проверка: ${reading.elapsedMs} мс · память процесса: ${(reading.rssBytes / 1048576).round()} МиБ',
                    'Load: ${_worker.loadMs} ms · check: ${reading.elapsedMs} ms · process memory: ${(reading.rssBytes / 1048576).round()} MiB',
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _worker.close();
    _input.dispose();
    super.dispose();
  }
}
