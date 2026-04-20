import 'package:harbor/harbor.dart'
    show RiscVAlu, RiscVAluFunct, RiscVMicroOpField;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';
import '../matrix_encoders.dart';

/// Microcode UPDATE: patch a live instruction's microcode through the
/// rmicrocode* CSRs and prove the CPU's behaviour changes. We rewrite addi's
/// Alu micro-op from ADD to SUB in the exec ROM, then run `addi x1, x2, 5`:
/// unpatched that is x2+5=25, patched it must be x2-5=15. A pure-HDL check (the
/// emulator does not model the ROM patch), so coreTest asserts the HDL result
/// directly. See project_hdl_microcode_coverage / project_microcode_update.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  final config = RiverCoreConfig(
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
    mxlen: RiscVMxlen.rv64,
    extensions: [rv64i, rv32i, rvZicsr, rvZifencei, rvPriv],
    interrupts: const [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
    microcodeMode: MicrocodeMode.full,
  );

  test('patch addi add->sub via rmicrocode CSRs changes execution', () async {
    // Compute the exec-ROM row index of addi's Alu micro-op and the SUB-patched
    // encoding for that row, straight from the microcode model.
    MicrocodeRom.mopEncodings = kMicroOpTable;
    final rom = MicrocodeRom(config.isa, encodings: kMicroOpTable);
    final addi = rom.operations.firstWhere((o) => o.mnemonic == 'addi');

    // Flat layout per op in encodedMops: [count, mop0, mop1, ...]. The Alu mop
    // sits at (op base) + 1 (count word) + (its position in the microcode).
    var base = 0;
    for (final op in rom.operations) {
      if (identical(op, addi)) break;
      base += 1 + op.microcode.length;
    }
    final aluPos = addi.microcode.indexWhere((m) => m is RiscVAlu);
    final aluRowIndex = base + 1 + aluPos;

    final origAlu = addi.microcode[aluPos] as RiscVAlu;
    final aluEnc = kMicroOpTable.firstWhere((e) => e.name == 'Alu');
    final patched = RiscVAlu(RiscVAluFunct.sub, origAlu.a, origAlu.b);
    final patchWord = aluEnc.encodeMop(patched, config.mxlen).toInt();

    // CSR encoders (matrix_encoders: csr=csrrw/rs/rc by f3, csri=immediate).
    int csrrw(int addr, int rs1) => csr(addr, rs1, 0x1, 0);
    int csrrwi(int addr, int zimm) => csri(addr, zimm, 0x5, 0);
    // Load a 32-bit value into rd (lui + addi, with the addi sign carry).
    List<int> li(int rd, int v) {
      v &= 0xFFFFFFFF;
      final lo = v & 0xFFF;
      var hi = (v >> 12) & 0xFFFFF;
      if (lo & 0x800 != 0) hi = (hi + 1) & 0xFFFFF;
      final loSigned = lo & 0x800 != 0 ? lo - 0x1000 : lo;
      return [lui(hi, rd), iimm(loSigned, rd, 0x0, rd)];
    }

    const aAddr = 0x7C4; // rmicrocodeaddr
    const dAddr = 0x7C5; // rmicrocodedata
    const cAddr = 0x7C6; // rmicrocodectl
    const push = 0x1, commit = 0x2, clear = 0x4;

    final program = <int>[
      iimm(20, 0, 0x0, 2), // addi x2, x0, 20  (normal add, before the patch)
      ...li(5, patchWord), // x5 = SUB-patched Alu row
      csrrw(dAddr, 5), // rmicrocodedata = x5
      csrrwi(cAddr, clear), // CLEAR staging
      csrrwi(cAddr, push), // PUSH  -> staging = patch word
      ...li(6, aluRowIndex), // x6 = exec ROM row index (bit63=0 -> exec ROM)
      csrrw(aAddr, 6), // rmicrocodeaddr = x6
      csrrwi(cAddr, commit), // COMMIT -> ROM[row] = staging
      iimm(5, 2, 0x0, 1), // addi x1, x2, 5  (patched: x2 - 5)
      nop,
    ];
    final nextPc = (program.length - 1) * 4;

    String memString(List<int> ws) {
      final sb = StringBuffer();
      for (final w in ws) {
        for (var b = 0; b < 4; b++) {
          sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }
      return sb.toString().trimRight();
    }

    await coreTest(
      memString(program),
      {Register.x1: 15}, // x2(20) - 5 = 15 (patched). Unpatched would be 25.
      config,
      nextPc: nextPc,
    );
  });
}
