// RISC-V instruction encoders shared by the matrix instruction table.

const nop = 0x00000013;

/// OP-IMM (addi/slli/...): opcode 0x13.
int iimm(int imm, int rs1, int f3, int rd) =>
    ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;

/// OP-IMM-32 (addiw/...): opcode 0x1B (rv64).
int iimmW(int imm, int rs1, int f3, int rd) =>
    ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x1B;

/// OP (add/sub/and/mul/...): opcode 0x33.
int rtype(int f7, int rs2, int rs1, int f3, int rd) =>
    (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33;

/// OP-32 (addw/subw/mulw/...): opcode 0x3B (rv64).
int rtypeW(int f7, int rs2, int rs1, int f3, int rd) =>
    (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x3B;

/// LOAD (lb/lh/lw/ld/...): opcode 0x03.
int load(int imm, int rs1, int f3, int rd) =>
    ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x03;

/// STORE (sb/sh/sw/sd): opcode 0x23.
int store(int imm, int rs2, int rs1, int f3) =>
    (((imm >> 5) & 0x7F) << 25) |
    (rs2 << 20) |
    (rs1 << 15) |
    (f3 << 12) |
    ((imm & 0x1F) << 7) |
    0x23;

/// LUI: opcode 0x37.
int lui(int imm20, int rd) => ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37;

/// AUIPC: opcode 0x17.
int auipc(int imm20, int rd) => ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x17;

/// BRANCH (beq/bne/blt/bge/bltu/bgeu): opcode 0x63. [imm] is the signed byte
/// offset (multiple of 2); the B-type immediate is scattered across the word.
int branch(int imm, int rs2, int rs1, int f3) =>
    (((imm >> 12) & 0x1) << 31) |
    (((imm >> 5) & 0x3F) << 25) |
    (rs2 << 20) |
    (rs1 << 15) |
    (f3 << 12) |
    (((imm >> 1) & 0xF) << 8) |
    (((imm >> 11) & 0x1) << 7) |
    0x63;

/// JAL: opcode 0x6F. [imm] is the signed byte offset; J-type scattered layout.
int jal(int imm, int rd) =>
    (((imm >> 20) & 0x1) << 31) |
    (((imm >> 1) & 0x3FF) << 21) |
    (((imm >> 11) & 0x1) << 20) |
    (((imm >> 12) & 0xFF) << 12) |
    (rd << 7) |
    0x6F;

/// JALR: opcode 0x67, funct3 0.
int jalr(int imm, int rs1, int rd) =>
    ((imm & 0xFFF) << 20) | (rs1 << 15) | (0x0 << 12) | (rd << 7) | 0x67;

/// SYSTEM CSR (csrrw/csrrs/csrrc): opcode 0x73. csr in bits[31:20], rs1 source.
int csr(int csrAddr, int rs1, int f3, int rd) =>
    ((csrAddr & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x73;

/// SYSTEM CSR immediate (csrrwi/csrrsi/csrrci): the 5-bit zimm sits in the rs1
/// field; funct3 has bit 2 set (0x5/0x6/0x7).
int csri(int csrAddr, int zimm, int f3, int rd) =>
    ((csrAddr & 0xFFF) << 20) |
    ((zimm & 0x1F) << 15) |
    (f3 << 12) |
    (rd << 7) |
    0x73;

/// LOAD-FP flw (funct3 0x2) / fld (funct3 0x3): opcode 0x07. rd is an F-reg.
int flw(int imm, int rs1, int fd) =>
    ((imm & 0xFFF) << 20) | (rs1 << 15) | (0x2 << 12) | (fd << 7) | 0x07;
int fld(int imm, int rs1, int fd) =>
    ((imm & 0xFFF) << 20) | (rs1 << 15) | (0x3 << 12) | (fd << 7) | 0x07;

/// STORE-FP fsw (funct3 0x2) / fsd (funct3 0x3): opcode 0x27. fs2 is an F-reg.
int fsw(int imm, int fs2, int rs1, int f3) =>
    (((imm >> 5) & 0x7F) << 25) |
    (fs2 << 20) |
    (rs1 << 15) |
    (f3 << 12) |
    ((imm & 0x1F) << 7) |
    0x27;

/// OP-FP R-type (fadd/fmul/fcvt/feq/fmv...): opcode 0x53. funct3 carries the
/// rounding mode for arithmetic, or a sub-op selector for compares/moves.
int fpOp(int funct7, int rs2, int rs1, int f3, int rd) =>
    (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x53;

/// vsetvli rd, rs1, vtypei: opcode 0x57, funct3=7 (OPCFG); vtypei in bits[30:20].
int vsetvli(int vtypei, int rs1, int rd) =>
    (vtypei << 20) | (rs1 << 15) | (0x7 << 12) | (rd << 7) | 0x57;

/// vle32.v vd, (rs1): unit-stride load, opcode 0x07, width(funct3)=6, vm=1.
int vle32(int rs1, int vd) =>
    (1 << 25) | (rs1 << 15) | (0x6 << 12) | (vd << 7) | 0x07;

/// vse32.v vs3, (rs1): unit-stride store, opcode 0x27, width=6, vm=1.
int vse32(int rs1, int vs3) =>
    (1 << 25) | (rs1 << 15) | (0x6 << 12) | (vs3 << 7) | 0x27;

/// OPIVV vector-vector op vd, vs2, vs1: opcode 0x57, funct3=0, vm=1.
int vopivv(int funct6, int vs2, int vs1, int vd) =>
    (funct6 << 26) | (1 << 25) | (vs2 << 20) | (vs1 << 15) | (vd << 7) | 0x57;

/// OPIVX vector-scalar op vd, vs2, rs1: funct3=4 (scalar from a GPR), vm=1.
int vopivx(int funct6, int vs2, int rs1, int vd) =>
    (funct6 << 26) |
    (1 << 25) |
    (vs2 << 20) |
    (rs1 << 15) |
    (0x4 << 12) |
    (vd << 7) |
    0x57;

/// OPIVI vector-immediate op vd, vs2, imm5: funct3=3, vm=1.
int vopivi(int funct6, int vs2, int imm5, int vd) =>
    (funct6 << 26) |
    (1 << 25) |
    (vs2 << 20) |
    ((imm5 & 0x1F) << 15) |
    (0x3 << 12) |
    (vd << 7) |
    0x57;

/// AMO (amoadd/amoswap/amocas/lr/sc): opcode 0x2F. funct5 in bits[31:27].
int amo(int funct5, int rs2, int rs1, int f3, int rd) =>
    (funct5 << 27) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x2F;
