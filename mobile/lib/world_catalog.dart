class WorldTopic {
  final String id, ru, en;
  const WorldTopic(this.id, this.ru, this.en);
  String text(String language) => language == 'ru' ? ru : en;
}

/// A deliberately small, reviewable catalog. Matching covers the WHOLE input;
/// no embeddings, substrings or removal of context can turn a risk into a topic.
const worldCatalog = [
  WorldTopic(
    'read_novel',
    'Стоит ли мне сегодня почитать роман?',
    'Should I read a novel tonight?',
  ),
  WorldTopic(
    'watch_comedy',
    'Стоит ли мне сегодня посмотреть комедию?',
    'Should I watch a comedy at home tonight?',
  ),
  WorldTopic(
    'draw_stars',
    'Стоит ли мне нарисовать звёзды в блокноте?',
    'Should I draw stars in my notebook?',
  ),
  WorldTopic(
    'listen_music',
    'Стоит ли мне послушать спокойную музыку дома?',
    'Should I listen to calm music at home?',
  ),
  WorldTopic(
    'read_mystery',
    'Стоит ли мне почитать детектив дома сегодня?',
    'Should I read a murder mystery at home tonight?',
  ),
  WorldTopic(
    'write_poem',
    'Стоит ли мне написать короткое стихотворение?',
    'Should I write a short poem?',
  ),
  WorldTopic(
    'paper_star',
    'Стоит ли мне сложить звезду из бумаги?',
    'Should I fold a paper star?',
  ),
  WorldTopic(
    'puzzle',
    'Стоит ли мне собрать пазл дома?',
    'Should I do a jigsaw puzzle at home?',
  ),
];

WorldTopic? topicById(String id) {
  for (final topic in worldCatalog) {
    if (topic.id == id) return topic;
  }
  return null;
}

String _normal(String text) => text
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r' +'), ' ')
    .replaceFirst(RegExp(r'[?.!]+$'), '');
WorldTopic? matchWorldTopic(String text, String language) {
  if (language != 'ru' && language != 'en') return null;
  final normalized = _normal(text);
  for (final topic in worldCatalog) {
    if (_normal(topic.text(language)) == normalized) return topic;
  }
  return null;
}
