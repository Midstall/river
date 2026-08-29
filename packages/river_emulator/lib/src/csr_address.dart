/// CSR address constants for the RISC-V emulator.
///
/// Maps standard RISC-V CSR names to their addresses.
enum CsrAddress {
  // Machine Information
  mvendorid(0xF11),
  marchid(0xF12),
  mimpid(0xF13),
  mhartid(0xF14),
  mconfigptr(0xF15),

  // Machine Trap Setup
  mstatus(0x300),
  misa(0x301),
  medeleg(0x302),
  mideleg(0x303),
  mie(0x304),
  mtvec(0x305),
  mcounteren(0x306),
  menvcfg(0x30A),
  mstatush(0x310),

  // Machine Trap Handling
  mscratch(0x340),
  mepc(0x341),
  mcause(0x342),
  mtval(0x343),
  mip(0x344),

  // Machine Counter/Timer
  mcycle(0xB00),
  minstret(0xB02),

  // Supervisor Trap Setup
  sstatus(0x100),
  sie(0x104),
  stvec(0x105),
  scounteren(0x106),
  senvcfg(0x10A),

  // Supervisor Trap Handling
  sscratch(0x140),
  sepc(0x141),
  scause(0x142),
  stval(0x143),
  sip(0x144),

  // Supervisor Address Translation
  satp(0x180),

  // User Trap Setup
  ustatus(0x000),
  uie(0x004),
  utvec(0x005),

  // User Trap Handling
  uscratch(0x040),
  uepc(0x041),
  ucause(0x042),
  utval(0x043),
  uip(0x044),

  // User Counter/Timer (read-only)
  cycle(0xC00),
  time(0xC01),
  instret(0xC02);

  final int address;

  const CsrAddress(this.address);

  static CsrAddress? find(int address) {
    for (final csr in CsrAddress.values) {
      if (csr.address == address) return csr;
    }
    return null;
  }
}
