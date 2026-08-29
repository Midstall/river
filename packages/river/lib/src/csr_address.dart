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

  // Hypervisor Trap Setup
  hstatus(0x600),
  hedeleg(0x602),
  hideleg(0x603),
  hie(0x604),
  hcounteren(0x606),
  hgeie(0x607),

  // Hypervisor Trap Handling
  htval(0x643),
  hip(0x644),
  hvip(0x645),
  htinst(0x64A),
  hgeip(0xE12),

  // Hypervisor Configuration / Timer / Translation
  henvcfg(0x60A),
  htimedelta(0x605),
  hgatp(0x680),

  // Virtual Supervisor (VS-mode) CSRs
  vsstatus(0x200),
  vsie(0x204),
  vstvec(0x205),
  vsscratch(0x240),
  vsepc(0x241),
  vscause(0x242),
  vstval(0x243),
  vsip(0x244),
  vsatp(0x280),

  // State Enable (Smstateen / Ssstateen)
  mstateen0(0x30C),
  mstateen1(0x30D),
  mstateen2(0x30E),
  mstateen3(0x30F),
  sstateen0(0x10C),
  sstateen1(0x10D),
  sstateen2(0x10E),
  sstateen3(0x10F),
  hstateen0(0x60C),
  hstateen1(0x60D),
  hstateen2(0x60E),
  hstateen3(0x60F),

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
  instret(0xC02),

  // Vector (V) extension
  vstart(0x008),
  vxsat(0x009),
  vxrm(0x00A),
  vcsr(0x00F),
  vl(0xC20),
  vtype(0xC21),
  vlenb(0xC22),

  // River custom M-mode CSRs (0x7C0-0x7FF)
  rcachectl(0x7C0),
  rcacheaddr(0x7C1),
  rcachesize(0x7C2),
  // Pipeline / speculation control. WARL, reset 0. Bit fields:
  //   [0] SSBD     - disable speculative store-bypass (force LSQ conservative)
  //   [1] BPD      - disable branch prediction (force not-taken)
  //   [2] SERIALIZE- fence-like serialize of speculative execution
  //   [3] DTLBFC   - flush the data TLB on every context switch
  rpipelinectl(0x7C3),
  // Microcode update (patchable microcode ROM). A ROM row can be wider than
  // XLEN, so a patch is staged through [rmicrocodedata] in XLEN-bit chunks then
  // committed.
  //   rmicrocodeaddr: ROM row index; bit[XLEN-1] selects exec(0) vs decode(1).
  //   rmicrocodedata: one XLEN-bit chunk of the row to stage.
  //   rmicrocodectl : write-pulse strobes (act for one cycle on any write):
  //       [0] PUSH  - staging = (staging << XLEN) | rmicrocodedata
  //       [1] COMMIT- write staging into the selected ROM[rmicrocodeaddr]
  //       [2] CLEAR - staging = 0
  rmicrocodeaddr(0x7C4),
  rmicrocodedata(0x7C5),
  rmicrocodectl(0x7C6),
  // Pipeline feature-discovery (machine read-only, 0xFC0). Bitmap from
  // RiverCoreConfig (see RiverCoreConfig.rpipelineCap): OoO/dual/specfetch/
  // predictor/LSQ/forwarding/specLSQ/icache/paging. Writes trap (RO address).
  rpipelinecap(0xFC0);

  final int address;

  const CsrAddress(this.address);

  static CsrAddress? find(int address) {
    for (final csr in CsrAddress.values) {
      if (csr.address == address) return csr;
    }
    return null;
  }
}
