import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// Repro attempt: does MRET with mstatus.MPP=S actually drop the core to
/// S-mode? On HW the delta NixOS boot wedges with priv=M while PC is kernel
/// code right after an __sbi_ecall + mret, suggesting mret returns to the epc
/// but leaves the privilege at M. This isolates that: set MPP=S, mret to a
/// target, then execute an M-ONLY csr read (mhartid, 0xf14). In real S-mode
/// that traps illegal (-> mtvec handler sets x7=0xDEAD). If mret wrongly stayed
/// in M-mode, the mhartid read succeeds and x7 stays 0.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig full() => RiverCoreConfigV1.full(
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    clock: const HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
  );

  int csrw(int csr, int rs1) => (csr << 20) | (rs1 << 15) | (0x1 << 12) | 0x73;
  int csrr(int csr, int rd) =>
      (csr << 20) | (0 << 15) | (0x2 << 12) | (rd << 7) | 0x73;
  int bne(int rs1, int rs2, int off) {
    final b12 = (off >> 12) & 1;
    final b11 = (off >> 11) & 1;
    final b10_5 = (off >> 5) & 0x3f;
    final b4_1 = (off >> 1) & 0xf;
    return (b12 << 31) |
        (b10_5 << 25) |
        (rs2 << 20) |
        (rs1 << 15) |
        (0x1 << 12) |
        (b4_1 << 8) |
        (b11 << 7) |
        0x63;
  }

  const ecall = 0x00000073;
  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  int slli(int rd, int rs1, int sh) =>
      (sh << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x13;
  const mret = 0x30200073;
  const jalLoop = 0x0000006F;
  const nop = 0x00000013;

  String words(List<int> ws) {
    final sb = StringBuffer();
    for (final w in ws) {
      for (var b = 0; b < 4; b++) {
        sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return sb.toString().trimRight();
  }

  test(
    'mret with MPP=S drops to S-mode (M-only csr then traps)',
    timeout: Timeout(Duration(minutes: 6)),
    () {
      // Layout (word index -> byte addr = idx*4):
      //  0 mtvec = 0x60 (handler)          @0x00
      //  1 csrw mtvec, x14
      //  2 mepc = 0x40 (target)            @0x08
      //  3 csrw mepc, x14
      //  4 x12 = 1                         @0x10
      //  5 slli x12,x12,11  (MPP=S=0x800)
      //  6 csrw mstatus, x12
      //  7 mret -> S-mode @0x40            @0x1c
      //  8..15 nops
      // 16 @0x40 target: x5 = 0xAB
      // 17 @0x44 csrr x6, mhartid (M-only) -> illegal in S -> mtvec
      // 18 @0x48 jal loop  (only reached if NO trap = mret bug)
      // ...
      // 24 @0x60 handler: x7 = 0xDEAD
      // 25 @0x64 jal loop
      final prog = words([
        addi(14, 0, 0x60), //  0
        csrw(0x305, 14), //    1 mtvec
        addi(14, 0, 0x40), //  2
        csrw(0x341, 14), //    3 mepc
        addi(12, 0, 1), //     4
        slli(12, 12, 11), //   5 MPP=S (0x800)
        csrw(0x300, 12), //    6 mstatus
        mret, //               7 @0x1c
        nop, nop, nop, nop, nop, nop, nop, nop, // 8..15
        addi(5, 0, 0xAB), //  16 @0x40 target (S-mode)
        csrr(0xf14, 6), //    17 @0x44 mhartid: illegal in S-mode
        jalLoop, //           18 @0x48 park (reached only if NOT trapped)
        nop, nop, nop, nop, nop, // 19..23
        addi(
          7,
          0,
          0xDEAD & 0x7FF,
        ), // 24 @0x60 handler marker (0x6AD in 11 bits)
        jalLoop, //           25 @0x64 park
      ]);
      // x5=0xAB proves we reached the target. x7=0x2AD proves the M-only read
      // trapped, i.e. mret correctly entered S-mode. If mret left the core in
      // M-mode, x7 stays 0 (bug reproduced).
      return coreTest(
        '@0\n$prog\n',
        {Register.x5: 0xAB, Register.x7: 0x6AD},
        full(),
        nextPc: 0x64,
      );
    },
  );

  test(
    'ecall-from-S round trip: hw trap-entry MPP=S, mret returns to S-mode',
    timeout: Timeout(Duration(minutes: 6)),
    () {
      // This is the REAL hang shape: S-mode does `ecall`, the hardware trap
      // entry must save mstatus.MPP=S, the M-mode handler mrets, and the core
      // must land back in S-mode. Observed on HW: after an SBI ecall the core
      // sits at a kernel PC with priv=M (mret left it in M).
      //
      //  M setup (0x00): mtvec=HANDLER(0x80), MPP=S, mepc=SCODE(0x40), mret
      //  SCODE (0x40, S): ecall -> handler -> returns here -> x5=0xAB ->
      //                   csrr mhartid (M-only): traps in S -> handler illegal
      //  HANDLER (0x80, M): if mcause==9 (ecall) skip+4 & mret;
      //                     else (illegal probe) x7=0x6AD, park.
      final prog = words([
        // ---- M setup @0x00 ----
        addi(14, 0, 0x80), //  0 HANDLER
        csrw(0x305, 14), //    1 mtvec
        addi(14, 0, 0x40), //  2 SCODE
        csrw(0x341, 14), //    3 mepc
        addi(12, 0, 1), //     4
        slli(12, 12, 11), //   5 MPP=S
        csrw(0x300, 12), //    6 mstatus
        mret, //               7 @0x1c -> S @0x40
        nop, nop, nop, nop, nop, nop, nop, nop, // 8..15 (0x20..0x3c)
        // ---- SCODE @0x40 (S-mode) ----
        ecall, //             16 @0x40 -> M handler
        addi(5, 0, 0xAB), //  17 @0x44 returned (S-mode if mret correct)
        csrr(0xf14, 6), //    18 @0x48 mhartid: illegal in S -> handler
        jalLoop, //           19 @0x4c park (only if M-mode bug: no trap)
        nop, nop, nop, nop, nop, nop, nop, nop, // 20..27 (0x50..0x6c)
        nop, nop, nop, nop, // 28..31 (0x70..0x7c)
        // ---- HANDLER @0x80 (M-mode) ----
        csrr(0x342, 13), //   32 @0x80 x13 = mcause
        addi(15, 0, 9), //    33 @0x84 x15 = 9 (ecall-from-S)
        bne(13, 15, 0x14), // 34 @0x88 if mcause!=9 -> illegal_path @0x9c
        csrr(0x341, 14), //   35 @0x8c x14 = mepc
        addi(14, 14, 4), //   36 @0x90 skip ecall
        csrw(0x341, 14), //   37 @0x94 mepc = mepc+4
        mret, //              38 @0x98 -> back to S @0x44
        addi(7, 0, 0x6AD), // 39 @0x9c illegal_path: S-mode confirmed
        jalLoop, //           40 @0xa0 park
      ]);
      // x5=0xAB: the ecall round trip returned. x7=0x6AD: it returned in
      // S-mode (the M-only mhartid read trapped). If mret returned to M-mode,
      // x7 stays 0 = bug reproduced.
      return coreTest(
        '@0\n$prog\n',
        {Register.x5: 0xAB, Register.x7: 0x6AD},
        full(),
        nextPc: 0xa0,
      );
    },
  );
}
