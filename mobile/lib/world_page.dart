import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'aura_renderer.dart';
import 'aura_ui.dart';
import 'world_catalog.dart';
import 'world_data.dart';

class WorldPage extends StatefulWidget {
  final WorldController controller;
  final String language, background;
  final bool active;
  final ValueChanged<WorldTopic> onSelect;
  const WorldPage({
    super.key,
    required this.controller,
    required this.language,
    required this.background,
    required this.active,
    required this.onSelect,
  });
  @override
  State<WorldPage> createState() => _WorldPageState();
}

class _WorldPageState extends State<WorldPage> {
  String _period = 'day';
  bool _ownLanguage = true, _busy = false;
  String t(String ru, String en) => widget.language == 'ru' ? ru : en;
  String get _filter => _ownLanguage ? widget.language : 'all';
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(WorldPage old) {
    super.didUpdateWidget(old);
    if (widget.active && (!old.active || old.language != widget.language)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) unawaited(_refresh());
      });
    }
  }

  Future<void> _refresh() async {
    if (_busy || !widget.controller.loaded) return;
    setState(() => _busy = true);
    await widget.controller.refresh(_period, _filter);
    if (mounted) setState(() => _busy = false);
  }

  Widget _choice(String label, bool selected, VoidCallback action) => Semantics(
    selected: selected,
    child: TextButton(
      onPressed: _busy ? null : action,
      style: TextButton.styleFrom(
        foregroundColor: selected ? Colors.white : const Color(0xffaabac7),
      ),
      child: Text(selected ? '· $label' : label),
    ),
  );
  Widget _topic(WorldTopic topic, {int? count}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextButton(
      key: ValueKey('${count == null ? 'catalog' : 'ranking'}-${topic.id}'),
      onPressed: () => widget.onSelect(topic),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 2),
        alignment: Alignment.centerLeft,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ExcludeSemantics(
            child: AuraIcon(
              kind: AuraIconKind.universe,
              color: auraAccent(widget.background),
              size: 22,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              topic.text(widget.language),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 12),
            Text(
              '≈ $count',
              semanticsLabel: t(
                'Около $count вопросов',
                'About $count questions',
              ),
            ),
          ],
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final text = base.textTheme;
    return Theme(
      data: base.copyWith(
        textTheme: text
            .apply(fontFamily: 'Manrope')
            .copyWith(
              headlineLarge: text.headlineLarge,
              headlineSmall: text.headlineSmall,
              titleLarge: text.titleLarge,
            ),
      ),
      child: Builder(builder: _content),
    );
  }

  Widget _content(BuildContext context) {
    final model = widget.controller;
    final snapshot = model.cache['$_period/$_filter'];
    final text = Theme.of(context).textTheme;
    return ListView(
      key: const ValueKey('world-page'),
      padding: const EdgeInsets.symmetric(horizontal: 28),
      children: [
        Semantics(
          header: true,
          child: Text(
            t('Что волнует мир', 'What moves the world'),
            style: text.headlineLarge,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          t('Общие темы. Личные решения.', 'Shared themes. Personal choices.'),
          style: text.bodySmall,
        ),
        SizedBox(
          height: 160,
          child: ExcludeSemantics(
            child: AuraScene(
              background: widget.background,
              form: 'constellation',
              active: widget.active,
              showBackground: false,
              child: const SizedBox.expand(),
            ),
          ),
        ),
        Wrap(
          spacing: 4,
          children: [
            for (final entry in [
              ('day', t('Сутки', 'Day')),
              ('week', t('Неделя', 'Week')),
              ('month', t('Месяц', 'Month')),
            ])
              _choice(entry.$2, _period == entry.$1, () {
                setState(() => _period = entry.$1);
                unawaited(_refresh());
              }),
          ],
        ),
        Wrap(
          spacing: 8,
          children: [
            _choice(t('На моём языке', 'My language'), _ownLanguage, () {
              setState(() => _ownLanguage = true);
              unawaited(_refresh());
            }),
            _choice(t('Весь мир', 'Worldwide'), !_ownLanguage, () {
              setState(() => _ownLanguage = false);
              unawaited(_refresh());
            }),
          ],
        ),
        const SizedBox(height: 18),
        if (snapshot != null) ...[
          if (snapshot.testing)
            Text(
              t(
                'Тестовые данные сервера — не статистика людей',
                'Server test data — not community statistics',
              ),
              style: text.bodyMedium,
            ),
          Text(
            '${t('По данным за полные дни до', 'Complete days through')} ${snapshot.through}',
            style: text.bodySmall,
          ),
          if (model.offline)
            Text(
              t(
                'Сеть недоступна. Показана сохранённая статистика.',
                'Offline. Showing saved statistics.',
              ),
              style: text.bodySmall,
            ),
          const SizedBox(height: 18),
          for (final item in snapshot.items) _topic(item.$1, count: item.$2),
          if (snapshot.items.isEmpty)
            Text(
              t(
                'Пока недостаточно данных для публикации.',
                'There is not enough data to publish yet.',
              ),
              style: text.bodyMedium,
            ),
        ] else
          Text(
            model.transport.configured
                ? t(
                    'Статистика пока недоступна. Каталог работает без сети.',
                    'Statistics are unavailable. The catalog works offline.',
                  )
                : t(
                    'Сервис статистики ещё не подключён. Здесь нет вымышленных счётчиков.',
                    'The statistics service is not connected yet. No invented counts are shown.',
                  ),
            style: text.bodyMedium,
          ),
        if (model.transport.configured)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _busy ? null : _refresh,
              child: Text(
                _busy ? t('Обновляем…', 'Updating…') : t('Обновить', 'Refresh'),
              ),
            ),
          ),
        const SizedBox(height: 12),
        Text(
          t(
            'Считаются вопросы, не люди. Публикация от 10 вопросов за завершённые дни; числа округлены вниз до 5.',
            'Counts refer to questions, not people. Publication starts at 10 questions across completed days; counts round down to 5.',
          ),
          style: text.bodySmall,
        ),
        const SizedBox(height: 30),
        Semantics(
          header: true,
          child: Text(
            t('Каталог для вдохновения', 'A little inspiration'),
            style: text.headlineSmall,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          t(
            'Это подготовленные примеры, а не рейтинг. Касание откроет редактор; ответ появится только после подтверждения и проверки.',
            'These are prepared examples, not a ranking. Tap to open the editor; an answer requires confirmation and a safety check.',
          ),
          style: text.bodySmall,
        ),
        const SizedBox(height: 18),
        for (final topic in worldCatalog) _topic(topic),
        if (model.failed)
          Text(
            t(
              'Кеш или настройки данных недоступны. Сбор остановлен.',
              'Cache or data settings are unavailable. Collection is stopped.',
            ),
          ),
        const SizedBox(height: 24),
      ],
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }
}
