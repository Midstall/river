import 'label.dart';
import 'module.dart';

extension ControlFlow on Module {
  void ifBlock({
    required void Function() condition,
    required void Function() then,
    void Function()? orElse,
  }) {
    final elseLabel = Label('_else_${instructions.length}');
    condition();

    if (orElse != null) {
      then();
      final end = Label('_endif_${instructions.length}');
      jal(end);
      placeLabel(elseLabel);
      orElse();
      placeLabel(end);
    } else {
      then();
      placeLabel(elseLabel);
    }
  }

  void whileLoop({
    required void Function() condition,
    required void Function() body,
  }) {
    final top = Label('_while_${instructions.length}');
    final end = Label('_wend_${instructions.length}');

    placeLabel(top);
    condition();
    body();
    jal(top);
    placeLabel(end);
  }

  void doWhile({
    required void Function() body,
    required void Function() condition,
  }) {
    final top = Label('_do_${instructions.length}');

    placeLabel(top);
    body();
    condition();
  }

  void forLoop({
    required void Function() init,
    required void Function() condition,
    required void Function() update,
    required void Function() body,
  }) {
    init();
    final top = Label('_for_${instructions.length}');
    final end = Label('_forend_${instructions.length}');

    placeLabel(top);
    condition();
    body();
    update();
    jal(top);
    placeLabel(end);
  }
}
