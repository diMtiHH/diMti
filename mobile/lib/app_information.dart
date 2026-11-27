import 'package:material_ui/material_ui.dart';

import 'world_data.dart';
import 'release_features.dart';

enum InformationSection { accessibility, privacy, terms, help, about }

String informationTitle(InformationSection value, String language) {
  final ru = language == 'ru';
  return switch (value) {
    InformationSection.accessibility =>
      ru ? 'Доступность и данные' : 'Accessibility and data',
    InformationSection.privacy => ru ? 'Конфиденциальность' : 'Privacy',
    InformationSection.terms => ru ? 'Условия использования' : 'Terms of use',
    InformationSection.help => ru ? 'Помощь и поддержка' : 'Help and support',
    InformationSection.about => ru ? 'О приложении' : 'About',
  };
}

class AppInformationPage extends StatefulWidget {
  final InformationSection section;
  final String language;
  final WorldController controller;
  const AppInformationPage({
    super.key,
    required this.section,
    required this.language,
    required this.controller,
  });
  @override
  State<AppInformationPage> createState() => _AppInformationPageState();
}

class _AppInformationPageState extends State<AppInformationPage> {
  bool _busy = false;
  String? _region;
  String t(String ru, String en) => widget.language == 'ru' ? ru : en;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _consent(bool enabled) async {
    if (enabled) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t('Поделиться только темой?', 'Share only the topic?')),
          content: SingleChildScrollView(
            child: Text(
              t(
                'Добровольно передавать код темы из каталога, язык, день UTC и число вопросов. Текст, имя, запись голоса и ответы не отправляются. Сервер видит сетевой адрес; полная анонимность не обещается. Отказ удалит неотправленные счётчики. Уже объединённые итоги нельзя выделить и удалить отдельно. В личной тестовой сборке счётчики не отправляются.',
                'Optionally send a catalog topic code, language, UTC day and question count. Question text, name, audio and answers are never sent. The server sees a network address; complete anonymity is not promised. Withdrawal deletes unsent counts. Contributions already merged into totals cannot be identified and removed separately. Personal test builds do not upload counts.',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('Не сейчас', 'Not now')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('Согласен', 'I agree')),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    setState(() => _busy = true);
    await widget.controller.setConsent(enabled);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final text = base.textTheme;
    return Theme(
      data: base.copyWith(
        textTheme: text
            .apply(fontFamily: 'Manrope')
            .copyWith(
              titleLarge: text.titleLarge,
              headlineSmall: text.headlineSmall,
            ),
      ),
      child: Builder(builder: _content),
    );
  }

  Widget _content(BuildContext context) {
    final model = widget.controller;
    final style = Theme.of(context).textTheme;
    final paragraphs = switch (widget.section) {
      InformationSection.privacy => [
        t(
          'Вопрос и аудио не сохраняются. Проверка вопроса и распознавание речи выполняются на устройстве. При недоступности локальной речи доступен ручной ввод.',
          'Question text and audio are not saved. Question checks and speech recognition run on your device. If local speech is unavailable, use text input.',
        ),
        t(
          'Локально хранятся имя, настройки, согласия, ещё не показанный ответ и состояние паузы. После начала паузы сохранённый ответ удаляется. Профиль, счётчики и состояние исключены из резервной копии приложения.',
          'Your name, preferences, consent, an unrevealed answer and pause state are stored locally. Once the pause starts, the saved answer is removed. Profile, counts and session records are excluded from app backup.',
        ),
        t(
          'Статистика выключена по умолчанию. После отдельного согласия можно передавать только код темы, язык, день и счётчик. В очереди нет идентификатора пользователя. Сетевой адрес технически виден серверу и посредникам. Сервер хранит дневные итоги до 30 дней, квитанции загрузок до 35 дней; журналы запросов в поставляемом API отключены.',
          'Statistics are off by default. Separate consent permits only a topic code, language, day and count. The queue contains no user identifier. Network addresses are technically visible to the server and intermediaries. The server retains daily totals for up to 30 days and upload receipts for up to 35 days; request logging is disabled in the supplied API.',
        ),
        t(
          'Отозвать согласие можно в «Доступность и данные». Неотправленные счётчики удаляются. Публичный рейтинг содержит только подготовленные формулировки и округлённые итоги; он не показывает личные вопросы.',
          'Withdraw consent in Accessibility and data. Unsent counts are deleted. Rankings show prepared wording and rounded totals, never personal questions.',
        ),
      ],
      InformationSection.terms => [
        t(
          'Личная тестовая версия. Приложение предлагает независимый случайный ответ ДА или НЕТ, а не прогноз, знание фактов или совет специалиста. Решение и его последствия остаются за тобой.',
          'Personal test version. The app offers an independent random YES or NO, not a prediction, factual knowledge or professional advice. The decision and its consequences remain yours.',
        ),
        t(
          'Разрешены только конкретные безопасные действия с небольшими последствиями. В этой сборке — формулировки из каталога, дополнительно прошедшие локальную модель. Опасные, медицинские, юридические и финансовые решения не допускаются.',
          'Only specific safe actions with low stakes are eligible. This build supports catalog phrases that also pass the local model. Dangerous, medical, legal and financial decisions are not eligible.',
        ),
        t(
          'После показа ответа начинается пауза 30 минут. В личной тестовой сборке есть временный сброс паузы. Он не выбирает новый ответ и не отключает проверку вопроса. Для публичной сборки этот инструмент отключается.',
          'A 30-minute pause starts after the answer is shown. Personal test builds include a temporary pause reset. It does not choose a new answer or disable question checks. The tool is disabled for public builds.',
        ),
        t(
          'Это условия личного тестирования. Публичный выпуск, окончательные юридические документы и звуковой образ ещё не приняты основателем.',
          'These terms cover personal testing. Public release, final legal documents and the sonic identity have not yet been accepted by the founder.',
        ),
      ],
      InformationSection.help => [
        t(
          'Экстренная помощь при непосредственной опасности: Россия — 112; страны Европейского союза — 112; США — 911. Используй номер страны, где находишься. Для других стран уточни местный номер заранее. Это номера экстренных служб, а не консультация приложения.',
          'For immediate danger: Russia — 112; European Union countries — 112; USA — 911. Use the number for the country you are in. For other countries, check the local number in advance. These are emergency services, not app support.',
        ),
        t(
          'Если приложение не может проверить вопрос, ответ не выбирается. Попробуй один из примеров каталога. Ошибка модели или хранилища не снимает паузу.',
          'If the app cannot check a question, it does not choose an answer. Try a catalog example. Model or storage errors do not remove the pause.',
        ),
        t(
          'Случайный ответ не подходит для решений о безопасности или здоровье. Если тебе или другому человеку угрожает непосредственная опасность, обратись в местную экстренную службу. Можно попросить человека, которому доверяешь, побыть рядом и помочь связаться со специалистом.',
          'A random answer is not appropriate for safety or health decisions. If you or someone else is in immediate danger, contact local emergency services. You can ask someone you trust to stay with you and help contact a professional.',
        ),
        t(
          'Этот текст доступен без интернета и во время паузы. Приложение не является экстренной или кризисной службой.',
          'This text is available offline and during the pause. The app is not an emergency or crisis service.',
        ),
        t(
          'Микрофон, уведомления и системное уменьшение движения можно настроить в настройках iPhone. В приложении доступен отдельный режим спокойного экрана.',
          'Microphone access, notifications and system Reduce Motion can be managed in iPhone Settings. The app also offers a quiet-screen option.',
        ),
        t(
          'Источники проверены 27.11.2026: МЧС России, Your Europe, National 911 Program.\nhttps://mchs.gov.ru/deyatelnost/bezopasnost-grazhdan/kak-pravilno-vyzvat-skoruyu_5\nhttps://europa.eu/youreurope/citizens/travel/security-and-emergencies/emergency/index_en.htm\nhttps://www.911.gov/calling-911/',
          'Sources checked 27 Nov 2026: Russian Ministry of Emergency Situations, Your Europe, National 911 Program.\nhttps://mchs.gov.ru/deyatelnost/bezopasnost-grazhdan/kak-pravilno-vyzvat-skoruyu_5\nhttps://europa.eu/youreurope/citizens/travel/security-and-emergencies/emergency/index_en.htm\nhttps://www.911.gov/calling-911/',
        ),
      ],
      InformationSection.about => [
        'Спроси Вселенную · Ask the Universe\n0.8.0 (14)',
        t(
          'Этапы 7–8. Личная сборка для проверки. Все основные действия работают без сети. Для статистики необходим отдельно подключённый сервер.',
          'Stages 7–8. Personal test build. Core features work offline. Statistics require a separately connected server.',
        ),
        t(
          'Четыре оригинальные звуковые среды и три звуковых события созданы процедурно для проекта. Звуки появления ДА и НЕТ одинаковы. Вся музыка встроена; потоковых сервисов нет.',
          'Four original sound environments and three event cues were synthesized for the project. YES and NO use the same reveal sound. All audio is bundled; no streaming service is used.',
        ),
        t(
          'Шрифты Manrope, Cormorant Garamond и Literata используются по SIL Open Font License. Озвучка знакомства пока тестовая; после знакомства приложение не говорит от имени Вселенной.',
          'Manrope, Cormorant Garamond and Literata use the SIL Open Font License. Onboarding narration is provisional; the app never speaks as the Universe after onboarding.',
        ),
      ],
      InformationSection.accessibility => <String>[],
    };
    return Scaffold(
      backgroundColor: const Color(0xff050d13),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(informationTitle(widget.section, widget.language)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(28),
          children: [
            if (widget.section == InformationSection.help) ...[
              DropdownButtonFormField<String>(
                key: const ValueKey('help-country'),
                initialValue: _region,
                itemHeight: null,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: t('Страна пребывания', 'Country you are in'),
                ),
                items: [
                  for (final entry in [
                    ('ru', t('Россия', 'Russia')),
                    (
                      'eu',
                      t('Страна Европейского союза', 'European Union country'),
                    ),
                    ('us', t('США', 'USA')),
                    ('other', t('Другая страна', 'Another country')),
                  ])
                    DropdownMenuItem(value: entry.$1, child: Text(entry.$2)),
                ],
                onChanged: (value) => setState(() => _region = value),
              ),
              const SizedBox(height: 16),
              if (_region != null)
                SelectableText(
                  _region == 'other'
                      ? t(
                          'Используй номер местной экстренной службы.',
                          'Use your local emergency services number.',
                        )
                      : '${t('Экстренная помощь', 'Emergency services')}: ${_region == 'us' ? '911' : '112'}',
                  style: style.titleLarge,
                ),
              const SizedBox(height: 24),
            ],
            for (final paragraph in paragraphs)
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: SelectableText(paragraph, style: style.bodyLarge),
              ),
            if (widget.section == InformationSection.accessibility) ...[
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(t('Спокойный экран', 'Quiet screen')),
                subtitle: Text(
                  t(
                    'Без фонового движения и длинных переходов. Системное уменьшение движения также учитывается.',
                    'No background motion or long transitions. System Reduce Motion is also respected.',
                  ),
                ),
                value: model.reduceMotion,
                onChanged: _busy || !model.loaded || model.failed
                    ? null
                    : model.setReduceMotion,
              ),
              const SizedBox(height: 24),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  t('Добровольная статистика', 'Optional statistics'),
                ),
                subtitle: Text(
                  t(
                    'Только тема из каталога и счётчик. Можно отказаться в любой момент.',
                    'Only a catalog topic and count. You can withdraw at any time.',
                  ),
                ),
                value: model.consent,
                onChanged: _busy || !model.loaded || model.failed
                    ? null
                    : _consent,
              ),
              if (personalTestBuild)
                Text(
                  t(
                    'В этой личной сборке тестовые вопросы не отправляются в рейтинг.',
                    'In this personal build, test questions are not sent to the ranking.',
                  ),
                  style: style.bodySmall,
                ),
              const SizedBox(height: 24),
              Text(
                t(
                  'Размер текста и VoiceOver следуют настройкам iPhone. У всех действий есть текстовые названия; результат доступен без звука, цвета и вибрации.',
                  'Text size and VoiceOver follow iPhone settings. Actions have text labels; the result is available without sound, color or vibration.',
                ),
                style: style.bodyLarge,
              ),
              if (model.failed)
                Text(
                  t(
                    'Настройки не удалось сохранить. Сбор остановлен.',
                    'Settings could not be saved. Collection is stopped.',
                  ),
                ),
              const SizedBox(height: 24),
              for (final section in InformationSection.values.where(
                (x) => x != InformationSection.accessibility,
              ))
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AppInformationPage(
                          section: section,
                          language: widget.language,
                          controller: model,
                        ),
                      ),
                    ),
                    child: Text(informationTitle(section, widget.language)),
                  ),
                ),
            ],
            if (widget.section == InformationSection.about)
              TextButton(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'Ask the Universe',
                  applicationVersion: '0.8.0',
                ),
                child: Text(t('Лицензии компонентов', 'Component licenses')),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }
}
