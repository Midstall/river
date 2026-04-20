import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

// Smstateen/Ssstateen state-enable CSRs. SE0 (mstateen0 bit 63) gates access to
// the lower-level state-enable CSRs from any mode below M: cleared -> illegal
// instruction. River implements only SE0; the other architectural bits gate
// features it does not have, so they are WARL-0.
void main() {
  group('Smstateen (state-enable CSRs)', () {
    late RiverCore core;
    const causeMask = 0x7FFFFFFFFFFFFFFF;
    const se0 = 1 << 63;

    // csrrs rd, csr, x0 -> a pure CSR read (rs1 = x0, no write-back).
    int csrr(int rd, int csr) => (csr << 20) | (2 << 12) | (rd << 7) | 0x73;

    setUp(() {
      final config = RiverCoreConfig(
        clock: const HarborClockConfig(
          name: 'test',
          rate: HarborFixedClockRate(10000),
        ),
        mxlen: RiscVMxlen.rv64,
        extensions: [
          rv64i,
          rv32i,
          rvZicsr,
          rvZifencei,
          rvPriv,
          rvSmstateen,
          rvSsstateen,
        ],
        interrupts: [],
        mmu: HarborMmuConfig(
          mxlen: RiscVMxlen.rv64,
          pagingModes: const [RiscVPagingMode.bare],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
        ),
        type: RiverCoreType.general,
      );
      final sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0, 0xFFFF),
          clockFrequency: 10000,
        ),
      );
      core = RiverCore(config, memDevices: Map.fromEntries([sram.mem!]));
      // A valid M-mode trap handler so a denied access does not fault on entry.
      core.csrs.write(CsrAddress.mtvec.address, 0x100, core);
    });

    test('SE0 clear -> S-mode sstateen0 access traps illegal (2)', () async {
      core.csrs.write(CsrAddress.mstateen0.address, 0, core); // SE0 = 0
      core.mode = PrivilegeMode.supervisor;
      await core.cycle(0x2000, csrr(6, CsrAddress.sstateen0.address));
      expect(
        core.csrs.read(CsrAddress.mcause.address, core) & causeMask,
        2,
        reason: 'sstateen0 denied -> illegal instruction',
      );
    });

    test('SE0 set -> S-mode sstateen0 reads 0, no trap', () async {
      core.csrs.write(CsrAddress.mstateen0.address, se0, core); // SE0 = 1
      core.csrs.write(CsrAddress.mcause.address, 0xEE, core); // sentinel
      core.mode = PrivilegeMode.supervisor;
      final next = await core.cycle(
        0x2000,
        csrr(6, CsrAddress.sstateen0.address),
      );
      expect(
        core.xregs[Register.x6],
        0,
        reason: 'no U-accessible state-enabled features -> reads 0',
      );
      expect(next, 0x2004, reason: 'access allowed, pc advances (no trap)');
      expect(
        core.csrs.read(CsrAddress.mcause.address, core),
        0xEE,
        reason: 'mcause untouched (no trap fired)',
      );
    });

    test('M-mode is never gated by stateen', () async {
      core.csrs.write(CsrAddress.mstateen0.address, 0, core); // SE0 = 0
      core.mode = PrivilegeMode.machine;
      final next = await core.cycle(
        0x2000,
        csrr(6, CsrAddress.sstateen0.address),
      );
      expect(next, 0x2004, reason: 'M-mode access proceeds regardless of SE0');
    });

    test('mstateen0 is WARL: only SE0 (bit 63) is writable', () {
      core.csrs.write(CsrAddress.mstateen0.address, -1, core); // all ones
      expect(
        core.csrs.read(CsrAddress.mstateen0.address, core),
        se0,
        reason: 'unimplemented-feature bits are WARL-0',
      );
    });
  });
}
