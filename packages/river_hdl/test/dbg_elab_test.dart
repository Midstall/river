import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

void main() {
  final cfg = WishboneConfig(addressWidth: 64, dataWidth: 64, selWidth: 8);

  test('RiverDebugSubsystem elaborates', () async {
    final sub = RiverDebugSubsystem(cfg, xlen: 64);
    await sub.build();
    final sv = sub.generateSynth();
    expect(sv.contains('RiverDebugModule'), isTrue);
    expect(sv.contains('SbaWishboneAdapter'), isTrue);
  });

  test('no FPGA target defaults to the ECP5 JTAGG tap', () async {
    final sub = RiverDebugSubsystem(cfg, xlen: 64);
    await sub.build();
    final sv = sub.generateSynth();
    expect(sv.contains('JTAGG'), isTrue);
    expect(sv.contains('BSCANE2'), isFalse);
  });

  test('Xilinx target taps BSCANE2 on USER1, not JTAGG', () async {
    final sub = RiverDebugSubsystem(
      cfg,
      xlen: 64,
      target: const HarborFpgaTarget.spartan7(
        device: 'xc7s50',
        package: 'csga324',
      ),
    );
    await sub.build();
    final sv = sub.generateSynth();
    expect(sv.contains('BSCANE2'), isTrue);
    // USER4 (openocd's bscan tunnel hardcodes USER4).
    expect(sv.contains('JTAG_CHAIN(4)'), isTrue);
    expect(sv.contains('JTAGG'), isFalse);
  });

  test('ECP5 target taps the JTAGG', () async {
    final sub = RiverDebugSubsystem(
      cfg,
      xlen: 64,
      target: const HarborFpgaTarget.ecp5(
        device: 'lfe5u-25f',
        package: 'CSFBGA285',
      ),
    );
    await sub.build();
    final sv = sub.generateSynth();
    expect(sv.contains('JTAGG'), isTrue);
    expect(sv.contains('BSCANE2'), isFalse);
  });
}
