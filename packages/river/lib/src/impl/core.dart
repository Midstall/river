export 'core/v1.dart';

enum RiverCoreChoice {
  rc1_s('rc1.s'),
  rc1_n('rc1.n');

  const RiverCoreChoice(this.name);

  final String name;

  static RiverCoreChoice? getChoice(String name) {
    for (final choice in RiverCoreChoice.values) {
      if (choice.name == name) return choice;
    }
    return null;
  }
}
