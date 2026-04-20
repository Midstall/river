import 'package:river/river.dart';

/// Shared instruction encoders and OoO config builders for the core_ooo_*
/// test files. Split out of core_ooo_test.dart so each test file stays well
/// under the per-file timeout (each test builds a fresh HDL core, ~30-40s).

// ── instruction encoders ──
int r(int f7, int rs2, int rs1, int f3, int rd) =>
    (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33;
int iimm(int imm, int rs1, int f3, int rd) =>
    (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
int s(int imm, int rs2, int rs1, int f3, int op) =>
    (((imm >> 5) & 0x7F) << 25) |
    (rs2 << 20) |
    (rs1 << 15) |
    (f3 << 12) |
    ((imm & 0x1F) << 7) |
    op;
int lw(int imm, int rs1, int rd) =>
    (imm << 20) | (rs1 << 15) | (0x2 << 12) | (rd << 7) | 0x03;
// B-type (branch). imm is the byte offset from the branch PC.
int b(int imm, int rs2, int rs1, int f3) =>
    (((imm >> 12) & 0x1) << 31) |
    (((imm >> 5) & 0x3F) << 25) |
    (rs2 << 20) |
    (rs1 << 15) |
    (f3 << 12) |
    (((imm >> 1) & 0xF) << 8) |
    (((imm >> 11) & 0x1) << 7) |
    0x63;
// CSR instruction (SYSTEM opcode 0x73). csr=addr, rs1/uimm, funct3=op.
int csr(int addr, int rs1, int f3, int rd) =>
    (addr << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x73;
// J-type (JAL). imm is the byte offset from the jump PC.
int jal(int imm, int rd) =>
    (((imm >> 20) & 0x1) << 31) |
    (((imm >> 1) & 0x3FF) << 21) |
    (((imm >> 11) & 0x1) << 20) |
    (((imm >> 12) & 0xFF) << 12) |
    (rd << 7) |
    0x6F;
// I-type JALR (funct3=0, opcode 0x67): target = rs1 + imm, link = pc + 4.
int jalr(int imm, int rs1, int rd) =>
    (imm << 20) | (rs1 << 15) | (0x0 << 12) | (rd << 7) | 0x67;

String prog(List<int> words) {
  final sb = StringBuffer('@0\n');
  for (final w in words) {
    for (var b = 0; b < 4; b++) {
      sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
  }
  return '$sb\n';
}

HarborMmuConfig _bareMmu() => HarborMmuConfig(
  mxlen: RiscVMxlen.rv32,
  pagingModes: const [RiscVPagingMode.bare],
  tlbLevels: const [],
  pmp: HarborPmpConfig.none,
);

HarborClockConfig _clk() =>
    HarborClockConfig(name: 'sysclk', rate: HarborFixedClockRate(48000000));

// ── config builders ──
RiverCoreConfig oooConfig() => RiverCoreConfig(
  clock: _clk(),
  mxlen: RiscVMxlen.rv32,
  extensions: [rv32i, rvZicsr, rvZifencei],
  interrupts: [],
  mmu: _bareMmu(),
  type: RiverCoreType.general,
  executionMode: ExecutionMode.outOfOrder,
);

RiverCoreConfig oooBConfig() => RiverCoreConfig(
  clock: _clk(),
  mxlen: RiscVMxlen.rv32,
  extensions: [rv32i, rvZicsr, rvZifencei, rvM, rvZba, rvZbb, rvZbs, rvZicond],
  interrupts: [],
  mmu: _bareMmu(),
  type: RiverCoreType.general,
  executionMode: ExecutionMode.outOfOrder,
);

RiverCoreConfig oooDualConfig() => RiverCoreConfig(
  clock: _clk(),
  mxlen: RiscVMxlen.rv32,
  extensions: [rv32i, rvZicsr, rvZifencei, rvM],
  interrupts: [],
  mmu: _bareMmu(),
  type: RiverCoreType.general,
  executionMode: ExecutionMode.outOfOrder,
  commitWidth: IssueWidth.dual,
);

RiverCoreConfig oooDualBufConfig() => RiverCoreConfig(
  clock: _clk(),
  mxlen: RiscVMxlen.rv32,
  extensions: [rv32i, rvZicsr, rvZifencei, rvM],
  interrupts: [],
  mmu: _bareMmu(),
  type: RiverCoreType.general,
  executionMode: ExecutionMode.outOfOrder,
  commitWidth: IssueWidth.dual,
  writeBufferDepth: 2,
);

RiverCoreConfig oooSpecConfig() => RiverCoreConfig(
  clock: _clk(),
  mxlen: RiscVMxlen.rv32,
  extensions: [rv32i, rvZicsr, rvZifencei, rvM],
  interrupts: [],
  mmu: _bareMmu(),
  type: RiverCoreType.general,
  executionMode: ExecutionMode.outOfOrder,
  commitWidth: IssueWidth.dual,
  speculativeFetch: true,
);
