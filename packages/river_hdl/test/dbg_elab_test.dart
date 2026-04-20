import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

void main() {
  test('RiverDebugSubsystem elaborates', () async {
    final cfg = WishboneConfig(addressWidth: 64, dataWidth: 64, selWidth: 8);
    final sub = RiverDebugSubsystem(cfg, xlen: 64);
    await sub.build();
    final sv = sub.generateSynth();
    expect(sv.contains('RiverDebugModule'), isTrue);
    expect(sv.contains('SbaWishboneAdapter'), isTrue);
  });
}
