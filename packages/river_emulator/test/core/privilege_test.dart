import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

import '../constants.dart';

void main() {
  cpuTests('Privilege ISA', (config) {
    late Sram sram;
    late RiverCore core;
    setUp(() {
      sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0, 0xFFFF),
          clockFrequency: (config.clock.rate as HarborFixedClockRate).frequency,
        ),
      );

      core = RiverCore(config, memDevices: Map.fromEntries([sram.mem!]));
    });

    test('MRET returns from trap', () async {
      core.reset();

      core.csrs.write(CsrAddress.mtvec.address, 0x80000000, core);
      core.csrs.write(CsrAddress.mepc.address, 0x200, core);

      var mstatus = core.csrs.read(CsrAddress.mstatus.address, core);
      mstatus = (mstatus & ~(0x3 << 11)) | (3 << 11);
      core.csrs.write(CsrAddress.mstatus.address, mstatus, core);

      final nextPc = await core.cycle(0x1000, 0x30200073);

      expect(nextPc, 0x200);
      expect(core.mode, PrivilegeMode.machine);
    });
  }, condition: (config) => config.hasSupervisor && config.hasUser);
}
