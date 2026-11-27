import 'package:material_ui/material_ui.dart';

import 'aura_renderer.dart';

const cosmicBackgrounds = auraEnvironments;
const cosmicAnswerStyles = auraForms;

// Legacy preferences map to new geometry, never to rejected old artwork.
String auraEnvironmentName(String value) => switch (value) {
  'nebula' => 'aurora',
  'blackHole' => 'gravity',
  'stars' || 'galaxy' || 'aurora' || 'gravity' => value,
  _ => 'aurora',
};
String auraFormName(String value) => switch (value) {
  'coin' => 'livingMatter',
  'sphere' => 'liquidMetal',
  'blackHole' => 'infinity',
  'livingMatter' || 'liquidMetal' || 'infinity' || 'constellation' => value,
  _ => 'livingMatter',
};

/// Compatibility entry point using the same procedural renderer as home.
class CosmicScene extends StatelessWidget {
  final String background;
  final bool active, animate;
  final Widget child;
  const CosmicScene({
    super.key,
    required this.background,
    required this.child,
    this.active = true,
    this.animate = true,
  });
  @override
  Widget build(BuildContext context) => AuraScene(
    background: auraEnvironmentName(background),
    active: active && animate,
    showForm: false,
    child: child,
  );
}

/// Decorative preview. It owns neither a question nor an answer operation.
class AnswerStylePreview extends StatelessWidget {
  final String style, environment;
  final bool active, animate;
  final double size;
  final String? semanticLabel;
  const AnswerStylePreview({
    super.key,
    required this.style,
    this.active = true,
    this.animate = true,
    this.size = 176,
    this.environment = 'aurora',
    this.semanticLabel,
  }) : assert(size > 0);
  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: semanticLabel ?? 'Decorative form preview',
    child: ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: AuraScene(
          background: auraEnvironmentName(environment),
          form: auraFormName(style),
          active: active && animate,
          showBackground: false,
          formAlignment: Alignment.center,
          preview: true,
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );
}
