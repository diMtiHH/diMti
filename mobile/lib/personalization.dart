import 'package:material_ui/material_ui.dart';

import 'cosmic_scene.dart';
import 'presentation_profile.dart';

String backgroundLabel(PresentationBackground value, String language) {
  final ru = language == 'ru';
  return switch (value) {
    PresentationBackground.stars => ru ? 'Звёздная пустота' : 'Starfield',
    PresentationBackground.galaxy =>
      ru ? 'Далёкая галактика' : 'Distant galaxy',
    PresentationBackground.nebula =>
      ru ? 'Космическая туманность' : 'Cosmic nebula',
    PresentationBackground.blackHole => ru ? 'Чёрная дыра' : 'Black hole',
  };
}

String answerStyleLabel(PresentationAnswerStyle value, String language) {
  final ru = language == 'ru';
  return switch (value) {
    PresentationAnswerStyle.coin => ru ? 'Монета' : 'Coin',
    PresentationAnswerStyle.sphere => ru ? 'Стеклянная сфера' : 'Glass sphere',
    PresentationAnswerStyle.blackHole => ru ? 'Чёрная дыра' : 'Black hole',
    PresentationAnswerStyle.constellation => ru ? 'Созвездие' : 'Constellation',
  };
}

class PersonalizationControls extends StatelessWidget {
  final PresentationProfile profile;
  final String language;
  final bool busy, active;
  final ValueChanged<PresentationProfile> onChanged;
  const PersonalizationControls({
    super.key,
    required this.profile,
    required this.language,
    required this.onChanged,
    this.busy = false,
    this.active = true,
  });
  @override
  Widget build(BuildContext context) {
    final ru = language == 'ru';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          ru ? 'Твоя Вселенная' : 'Your Universe',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final background in PresentationBackground.values)
              ChoiceChip(
                key: ValueKey('background-${background.name}'),
                selected: profile.background == background,
                label: Text(backgroundLabel(background, language)),
                onSelected: busy
                    ? null
                    : (_) =>
                          onChanged(profile.copyWith(background: background)),
              ),
          ],
        ),
        const SizedBox(height: 28),
        Text(
          ru ? 'Способ получения ответа' : 'How the answer appears',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final style in PresentationAnswerStyle.values)
              ChoiceChip(
                key: ValueKey('answer-style-${style.name}'),
                selected: profile.answerStyle == style,
                label: Text(answerStyleLabel(style, language)),
                onSelected: busy
                    ? null
                    : (_) => onChanged(profile.copyWith(answerStyle: style)),
              ),
          ],
        ),
        const SizedBox(height: 24),
        Center(
          child: AnswerStylePreview(
            style: profile.answerStyle.name,
            active: active,
            semanticLabel: ru
                ? 'Предпросмотр стиля, не ответ'
                : 'Style preview, not an answer',
          ),
        ),
        Text(
          ru
              ? 'Предпросмотр · без вопроса и ответа'
              : 'Preview · no question or answer',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
