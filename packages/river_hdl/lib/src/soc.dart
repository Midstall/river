// River SoC generation is handled by GenIpConfig.buildSoC() in genip.dart,
// which constructs a HarborSoC directly.
//
// For programmatic use:
//   final config = GenIpConfig(name: 'my_soc', coreModel: 'rc1-s', ...);
//   final soc = config.buildSoC();
//   await soc.generateAll(Directory('output'));
