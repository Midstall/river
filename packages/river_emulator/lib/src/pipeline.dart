import 'package:harbor/harbor.dart' hide PrivilegeMode;
import 'package:river/river.dart';

import 'core.dart';

enum EmulatorStage { interrupt, fetch, decode, execute, trap }

typedef StageHandler = Future<void> Function(PipelineContext ctx);

class PipelineContext {
  int pc;
  int? instruction;
  RiscVOperation? op;
  RiverCoreState? state;
  bool halted = false;

  PipelineContext(this.pc);
}

class EmulatorPipeline {
  final List<EmulatorStage> _order;
  final Map<EmulatorStage, List<StageHandler>> _handlers = {};

  EmulatorPipeline({List<EmulatorStage>? order})
    : _order = order ?? EmulatorStage.values;

  void at(EmulatorStage stage, StageHandler handler) {
    _handlers.putIfAbsent(stage, () => []).add(handler);
  }

  Future<int> run(PipelineContext ctx) async {
    for (final stage in _order) {
      if (ctx.halted) break;
      final handlers = _handlers[stage];
      if (handlers == null) continue;
      for (final handler in handlers) {
        if (ctx.halted) break;
        await handler(ctx);
      }
    }
    return ctx.pc;
  }
}

abstract class EmulatorPipelinePlugin extends FiberPlugin {
  EmulatorStage get stage;

  Future<void> handle(PipelineContext ctx);

  @override
  void init() {
    during.build(() async {
      final elem = host.database.get<EmulatorPipeline>(kPipelineKey);
      final pipeline = (elem as HarborValueElement<EmulatorPipeline>).value;
      pipeline.at(stage, handle);
    });
  }
}

const kPipelineKey = HarborDatabaseKey<EmulatorPipeline>('emulator.pipeline');
