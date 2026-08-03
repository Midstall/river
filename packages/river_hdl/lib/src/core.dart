import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'data_port.dart';

import 'core/csr.dart';
import 'core/mmu.dart';
import 'core/pipeline.dart';
import 'inferred_rom.dart';

import 'compat.dart' show kMicroOpTable;
import 'microcode_rom.dart';

class RiverCore extends BridgeModule {
  final RiverCoreConfig config;

  late final HarborRegisterFile regs;
  late final DataPortInterface regWritePort;
  late final RiverPipeline pipeline;

  RiverCore(
    this.config, {
    Map<String, Logic> srcIrqs = const {},
    List<String> staticInstructions = const [],
    WishboneConfig? busConfig,
    HarborDeviceTarget? target,
    bool withDebug = false,
    // Expose plain bustap_ack/bustap_datmiso outputs mirroring the Wishbone
    // master's incoming ACK/read data for a logic analyzer. ACK is an input
    // here, so it must be mirrored to a plain output to stay hierarchy-legal.
    // Off in production.
    bool busTap = false,
    // Test-only backdoor: when high, an architectural regWritePort write also
    // seeds the OoO physical regfile. Asserted only while frozen during seeding;
    // null leaves it tied off.
    Logic? prfSeedMode,
    super.name = 'river_core',
  }) : super('RiverCore') {
    final wbConfig =
        busConfig ??
        WishboneConfig(
          addressWidth: config.mxlen.size,
          dataWidth: config.mxlen.size,
          selWidth: config.mxlen.size ~/ 8,
        );

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    final clk = input('clk');
    final reset = input('reset');

    final microcode = MicrocodeRom(config.isa, encodings: kMicroOpTable);

    final pipelineEnable = Logic(name: 'pipelineEnable');
    final pc = Logic(name: 'pc', width: config.mxlen.size);
    final sp = Logic(name: 'sp', width: config.mxlen.size);
    final mode = Logic(name: 'mode', width: 3);
    // Virtualization (V) mode bit, only meaningful with H. Pushed to
    // {m,s}status.{MPV,SPV} and restored on MRET/SRET.
    final virt = config.hasHypervisor ? Logic(name: 'virt') : null;
    // Per-access "treat as guest" = virt | (HLV/HSV in flight). Drives the MMU's
    // VS/G-stage routing. Forward-declared; driven after the pipeline.
    final guestAccessWire = config.hasHypervisor
        ? Logic(name: 'guestAccess')
        : null;
    final interruptHold = Logic(name: 'interruptHold');
    final fence = Logic(name: 'fence');

    // Optional external debug (RISC-V Debug Module) halt/resume. Freezes the
    // core at an instruction boundary and latches its PC into dpc.
    Logic? debugHalted;
    Logic? debugDpc;
    // Debug control/status register (dcsr, CSR 0x7b0). Must be a real
    // readable/writable register (OpenOCD reads cause/priv and writes
    // ebreak/step bits during resume) or resume wedges.
    Logic? debugDcsr;
    // High when a committing ebreak should enter Debug Mode (dcsr.ebreak* set for
    // the current privilege) instead of taking a breakpoint trap.
    Logic? ebreakDebug;
    Logic? haltReqIn;
    Logic? resumeReqIn;
    // Abstract-command register access (driven by the Debug Module while halted).
    Logic? dbgGprRead; // read a GPR onto the regfile read port
    Logic? dbgGprWrite; // write a GPR through the regfile write port
    Logic? dbgGprIdx; // 5-bit GPR index
    Logic? dbgIsDpc; // regno == dpc (0x7b1)
    Logic? dbgIsDcsr; // regno == dcsr (0x7b0)
    Logic? dbgIsMisa; // regno == misa (0x301)
    Logic? dbgRegWdata;
    Logic? dbgIsGpr; // regno is a GPR (bit 12 set)
    Logic? dbgRegAddr12; // low 12 bits of the regno = the CSR address
    Logic? dbgCsrSel; // halted && the regno is a CSR (borrow the CSR read port)
    Logic? dbgCsrData; // CSR file read result for a debug CSR access
    if (withDebug) {
      createPort('debug_halt_req', PortDirection.input);
      createPort('debug_resume_req', PortDirection.input);
      createPort('debug_reg_read', PortDirection.input);
      createPort('debug_reg_write', PortDirection.input);
      createPort('debug_reg_addr', PortDirection.input, width: 16);
      createPort(
        'debug_reg_wdata',
        PortDirection.input,
        width: config.mxlen.size,
      );
      addOutput('debug_halted');
      addOutput('debug_dpc', width: config.mxlen.size);
      addOutput('debug_reg_rdata', width: config.mxlen.size);
      addOutput('debug_reg_ready');
      haltReqIn = input('debug_halt_req');
      resumeReqIn = input('debug_resume_req');
      debugHalted = Logic(name: 'debugHalted');
      debugDpc = Logic(name: 'debugDpc', width: config.mxlen.size);
      debugDcsr = Logic(name: 'debugDcsr', width: 32);
      ebreakDebug = Logic(name: 'ebreakDebug');
      output('debug_halted') <= debugHalted;
      output('debug_dpc') <= debugDpc;

      final regAddr = input('debug_reg_addr');
      // GPR regnos are 0x1000..0x101f (bit 12 set); CSRs are < 0x1000.
      final isGpr = regAddr[12];
      dbgGprIdx = regAddr.getRange(0, 5);
      dbgIsDpc = regAddr.eq(0x7b1);
      dbgIsDcsr = regAddr.eq(0x7b0);
      // misa is a read-only constant (the configured ISA). Serve it directly so
      // a debugger can probe extensions over JTAG; else the abstract CSR read
      // falls through to the GPR port and reads 0.
      dbgIsMisa = regAddr.eq(0x301);
      dbgRegWdata = input('debug_reg_wdata');
      dbgGprRead = input('debug_reg_read') & isGpr;
      dbgGprWrite = input('debug_reg_write') & isGpr & debugHalted;
      // CSR abstract reads: while halted the pipeline is frozen, so the Debug
      // Module borrows the CSR read port. The regno IS the CSR address (regnos
      // < 0x1000), so present regAddr[11:0] and route the result back. Only the
      // read port is borrowed; CSR writes over abstract command are unimplemented.
      dbgIsGpr = isGpr;
      dbgRegAddr12 = regAddr.getRange(0, 12);
      if (config.hasCsrs) {
        dbgCsrSel = ~isGpr & debugHalted;
        dbgCsrData = Logic(name: 'dbgCsrData', width: config.mxlen.size);
      }
      // The register file is zero-latency, so the access is always ready.
      output('debug_reg_ready') <= Const(1);
    }

    final pagingMode = Logic(
      name: 'pagingMode',
      width: config.mmu.pagingModes
          .map((m) => m.id)
          .fold(0, (a, b) => a > b ? a : b)
          .bitLength
          .clamp(1, 64),
    );

    final pageTableAddress = Logic(
      name: 'pageTableAddress',
      width: config.mxlen.size,
    );

    // satp.MODE (4 bits) and root PPN, forward-declared to feed the MMU (built
    // before the CSR file). Assigned from the CSR file's satp once it exists.
    final satpModeWire = Logic(name: 'satpModeWire', width: 4);
    final satpRootWire = Logic(name: 'satpRootWire', width: config.mxlen.size);

    // Hypervisor G-stage (hgatp) mode/root for two-stage translation, fed to the
    // MMU when the config has H. Driven from an hgatp shadow register below.
    final gModeWire = config.hasHypervisor
        ? Logic(name: 'gModeWire', width: 4)
        : null;
    final gRootWire = config.hasHypervisor
        ? Logic(name: 'gRootWire', width: config.mxlen.size)
        : null;

    final enableMxr = Logic(name: 'enableMxr');
    final enableSum = Logic(name: 'enableSum');
    // DTLBFC (rpipelinectl[3]): drives the MMU's flush-data-TLB-on-priv-change.
    // Forward-declared here, driven from the CSR file below (mirrors enableMxr).
    final dtlbFlushOnPriv = Logic(name: 'dtlbFlushOnPriv');

    // Pipeline uses DataPortInterfaces internally; bridge them to the MMU ports.

    final dualDispatch = config.issueWidth == IssueWidth.dual;

    // Fetch read: pipeline drives en/addr, MMU responds with data/done/valid
    final pipeFetchRead = DataPortInterface(
      config.mxlen.size,
      config.mxlen.size,
    );
    // Dual-dispatch: a second fetch port (lane 1). Both lanes arbitrate onto the
    // MMU's single ifetch port below (lane 0 priority), serialising on the shared
    // bus, but each lane keeps its own request/response interface so the
    // front-end can present a 2-instruction bundle to rename.
    final pipeFetchRead1 = dualDispatch
        ? DataPortInterface(config.mxlen.size, config.mxlen.size)
        : null;
    // Exec read: same pattern
    final pipeExecRead = DataPortInterface(
      config.mxlen.size,
      config.mxlen.size,
    );
    // Exec write: pipeline drives en/addr/data (with sized prefix), MMU responds done/valid
    final pipeExecWrite = DataPortInterface(
      config.mxlen.size + 7,
      config.mxlen.size,
    );

    // Bridge fetch → MMU ifetch
    // Bridge exec read/write → single dport
    final execWriteActive = pipeExecWrite.en;

    // swizzle layout: {size[6:0], value[xlen-1:0]} MSB-first
    // So value is bits [xlen-1:0] and size is bits [xlen+6:xlen]
    final writeValue = pipeExecWrite.data.getRange(0, config.mxlen.size);
    final writeSizePrefix = pipeExecWrite.data.getRange(
      config.mxlen.size,
      config.mxlen.size + 7,
    );
    final writeLog2Size = mux(
      writeSizePrefix[0],
      Const(0, width: 3),
      mux(
        writeSizePrefix[1],
        Const(1, width: 3),
        mux(
          writeSizePrefix[2],
          Const(2, width: 3),
          mux(writeSizePrefix[3], Const(3, width: 3), Const(2, width: 3)),
        ),
      ),
    );

    final dportEn = mux(execWriteActive, Const(1), pipeExecRead.en);
    final dportAddr = mux(
      execWriteActive,
      pipeExecWrite.addr,
      pipeExecRead.addr,
    );
    final dportWe = execWriteActive;
    final dportWdata = mux(
      execWriteActive,
      writeValue.zeroExtend(config.mxlen.size),
      Const(0, width: config.mxlen.size),
    );
    final dportSize = mux(execWriteActive, writeLog2Size, Const(2, width: 3));

    // Wishbone ACK/MISO from external bus
    final wbAckExt = Logic(name: 'wbAckExt');
    final wbDatMisoExt = Logic(name: 'wbDatMisoExt', width: wbConfig.dataWidth);

    // Fetch arbiter (dual-dispatch): multiplex the two fetch lanes onto the
    // MMU's single ifetch port. Round-robin so both lanes make progress (a
    // FetchUnit keeps its request asserted while holding a delivered instruction,
    // so fixed priority would starve the other lane). A grant is held until the
    // in-flight fetch completes; the next grant prefers the lane not served last.
    final fetchActive = Logic(name: 'fetchActive');
    final fetchGrantP1 = Logic(name: 'fetchGrantP1');
    final lastGrantP1 = Logic(name: 'lastGrantP1');
    final bothReq = dualDispatch
        ? (pipeFetchRead.en & pipeFetchRead1!.en)
        : Const(0);
    final onlyP1 = dualDispatch
        ? (~pipeFetchRead.en & pipeFetchRead1!.en)
        : Const(0);
    final newGrantP1 = mux(bothReq, ~lastGrantP1, onlyP1);
    final grantP1Now = dualDispatch
        ? mux(fetchActive, fetchGrantP1, newGrantP1)
        : Const(0);
    final ifetchEnArb = dualDispatch
        ? mux(grantP1Now, pipeFetchRead1!.en, pipeFetchRead.en)
        : pipeFetchRead.en;
    final ifetchAddrArb = dualDispatch
        ? mux(grantP1Now, pipeFetchRead1!.addr, pipeFetchRead.addr)
        : pipeFetchRead.addr;

    // Optional L1 instruction cache between the fetch unit(s) and the MMU ifetch
    // port. Hits in one cycle; misses fill a line from the MMU (its miss port
    // drives the MMU ifetch instead of the arbiter). Dual-dispatch serves both
    // lanes the same cycle on a shared-line hit.
    // On creek (DDR behind the FPGA PHY) the L1 is a correctness lever: each miss
    // fills one paced word at a time, so the PHY only sees single reads it
    // captures correctly, never a back-to-back burst. The D-cache extends the
    // same pacing to data loads.
    final l1 = config.l1cache;
    final useICache = l1?.i != null;
    final useDCache = l1 != null;

    final icMemDone = Logic(name: 'icMemDone');
    final icMemValid = Logic(name: 'icMemValid');
    final icMemRdata = Logic(name: 'icMemRdata', width: config.mxlen.size);
    final icFlush = Logic(name: 'icFlush');
    // Driven from pipeline.fence below (forward ref); flushes the MMU fetch TLB.
    final mmuTlbFlush = Logic(name: 'mmuTlbFlush');

    HarborL1ICache? icache;
    if (useICache) {
      icache = HarborL1ICache(
        config: l1!.i!,
        xlen: config.mxlen.size,
        dualPort: dualDispatch,
        // 32 physical bits cover the fetch space (DRAM at 0x80000000 + <=1GB); a
        // narrower tag packs far fewer LUTs than a full xlen compare.
        physAddrBits: 32,
        // Maps the per-line data to a block RAM (DP16KD / RAMB36E1).
        target: target,
      );
      addSubModule(icache);
      icache.input('clk').srcConnection! <= clk;
      icache.input('reset').srcConnection! <= reset;
      icache.input('req_addr').srcConnection! <= pipeFetchRead.addr;
      icache.input('req_valid').srcConnection! <= pipeFetchRead.en;
      icache.input('flush').srcConnection! <= icFlush;
      icache.input('mem_done').srcConnection! <= icMemDone;
      icache.input('mem_valid').srcConnection! <= icMemValid;
      icache.input('mem_rdata').srcConnection! <= icMemRdata;
      if (dualDispatch) {
        icache.input('req_addr1').srcConnection! <= pipeFetchRead1!.addr;
        icache.input('req_valid1').srcConnection! <= pipeFetchRead1.en;
      }
    }
    final ifetchEnFinal = useICache ? icache!.memEn : ifetchEnArb;
    final ifetchAddrFinal = useICache ? icache!.memAddr : ifetchAddrArb;

    // L1 data cache. Instantiated before the MMU because it drives the MMU dport
    // (load fills and write-through stores); the response feeds back through the
    // dc* wires. Write-through, no-write-allocate: stores go straight to DRAM
    // and invalidate any resident line, so no dirty-eviction burst is launched
    // into the marginal PHY.
    final dcMemDone = Logic(name: 'dcMemDone');
    final dcMemValid = Logic(name: 'dcMemValid');
    final dcMemRdata = Logic(name: 'dcMemRdata', width: config.mxlen.size);
    final dFlush = Logic(name: 'dFlush');
    HarborL1DCache? dcache;
    if (useDCache) {
      dcache = HarborL1DCache(
        config: l1.d,
        xlen: config.mxlen.size,
        physAddrBits: 32,
        target: target,
      );
      addSubModule(dcache);
      dcache.input('clk').srcConnection! <= clk;
      dcache.input('reset').srcConnection! <= reset;
      dcache.input('req_addr').srcConnection! <= dportAddr;
      dcache.input('req_valid').srcConnection! <= dportEn;
      dcache.input('req_write').srcConnection! <= dportWe;
      dcache.input('req_data').srcConnection! <= writeValue;
      dcache.input('req_size').srcConnection! <= dportSize;
      dcache.input('flush').srcConnection! <= dFlush;
      dcache.input('mem_done').srcConnection! <= dcMemDone;
      dcache.input('mem_valid').srcConnection! <= dcMemValid;
      dcache.input('mem_rdata').srcConnection! <= dcMemRdata;
    }
    // Data-port request to the MMU: from the D-cache when present, else direct.
    final dportEnFinal = useDCache ? dcache!.memEn : dportEn;
    final dportAddrFinal = useDCache ? dcache!.memAddr : dportAddr;
    final dportWeFinal = useDCache ? dcache!.memWe : dportWe;
    final dportWdataFinal = useDCache ? dcache!.memWdata : dportWdata;
    final dportSizeFinal = useDCache ? dcache!.memSize : dportSize;

    // MMU.
    final mmu = RiverMmu(
      clk,
      reset,
      ifetchEnFinal,
      ifetchAddrFinal,
      dportEnFinal,
      dportAddrFinal,
      dportWeFinal,
      dportWdataFinal,
      dportSizeFinal,
      wbAckExt,
      wbDatMisoExt,
      mmuConfig: config.mmu,
      busConfig: wbConfig,
      satpMode: config.mmu.hasPaging ? satpModeWire : null,
      satpRoot: config.mmu.hasPaging ? satpRootWire : null,
      virtIn: config.hasHypervisor ? guestAccessWire : null,
      gMode: config.hasHypervisor ? gModeWire : null,
      gRoot: config.hasHypervisor ? gRootWire : null,
      privMode: config.mmu.hasPaging ? mode : null,
      sum: config.mmu.hasPaging ? enableSum : null,
      mxr: config.mmu.hasPaging ? enableMxr : null,
      // Translate instruction fetches (below M-mode). Gated off when an icache
      // sits in front, since the icache does not yet propagate ifetch_fault.
      translateFetch: config.mmu.hasPaging && !useICache,
      tlbFlush: config.mmu.hasPaging ? mmuTlbFlush : null,
      dtlbFlushOnPrivChange: config.mmu.hasPaging ? dtlbFlushOnPriv : null,
    );

    if (useICache) {
      // The icache owns the MMU ifetch port (its miss fills); fetch responses
      // come from the cache. flush on fence.i (driven from the pipeline below).
      icMemDone <= mmu.ifetchDone;
      icMemValid <= mmu.ifetchValid;
      icMemRdata <= mmu.ifetchRdata;
      pipeFetchRead.done <= icache!.respValid;
      pipeFetchRead.valid <= icache.respValid;
      pipeFetchRead.data <= icache.respData;
      if (dualDispatch) {
        pipeFetchRead1!.done <= icache.respValid1;
        pipeFetchRead1.valid <= icache.respValid1;
        pipeFetchRead1.data <= icache.respData1;
      }
    } else if (dualDispatch) {
      // Route the ifetch response to whichever lane currently holds the grant.
      pipeFetchRead.done <= mmu.ifetchDone & ~grantP1Now;
      pipeFetchRead.valid <= mmu.ifetchValid & ~grantP1Now;
      pipeFetchRead.data <= mmu.ifetchRdata;
      pipeFetchRead1!.done <= mmu.ifetchDone & grantP1Now;
      pipeFetchRead1.valid <= mmu.ifetchValid & grantP1Now;
      pipeFetchRead1.data <= mmu.ifetchRdata;
      Sequential(clk, [
        If(
          reset,
          then: [fetchActive < 0, fetchGrantP1 < 0, lastGrantP1 < 0],
          orElse: [
            If(
              ~fetchActive,
              then: [
                If(
                  pipeFetchRead.en | pipeFetchRead1.en,
                  then: [
                    fetchActive < 1,
                    fetchGrantP1 < newGrantP1,
                    lastGrantP1 < newGrantP1,
                  ],
                ),
              ],
              orElse: [
                If(mmu.ifetchDone, then: [fetchActive < 0]),
              ],
            ),
          ],
        ),
      ]);
    } else {
      pipeFetchRead.done <= mmu.ifetchDone;
      pipeFetchRead.valid <= mmu.ifetchValid;
      pipeFetchRead.data <= mmu.ifetchRdata;
    }

    if (useDCache) {
      // MMU dport response feeds the D-cache; the D-cache serves the pipeline
      // (a hit in one cycle, a miss after its paced fill, a store once memory
      // acknowledges the write-through).
      dcMemDone <= mmu.dportDone;
      dcMemValid <= mmu.dportValid;
      dcMemRdata <= mmu.dportRdata;
      pipeExecRead.done <= dcache!.respValid & ~execWriteActive;
      pipeExecRead.valid <= dcache.respValid & ~execWriteActive;
      pipeExecRead.data <= dcache.respData;
      pipeExecWrite.done <= dcache.respValid & execWriteActive;
      pipeExecWrite.valid <= dcache.respValid & execWriteActive;
    } else {
      pipeExecRead.done <= mmu.dportDone & ~execWriteActive;
      pipeExecRead.valid <= mmu.dportValid & ~execWriteActive;
      pipeExecRead.data <= mmu.dportRdata;

      pipeExecWrite.done <= mmu.dportDone & execWriteActive;
      pipeExecWrite.valid <= mmu.dportValid & execWriteActive;
    }

    // Expose Wishbone bus master as a proper interface
    final dataBusRef = addInterface(
      WishboneInterface(wbConfig),
      name: 'dataBus',
      role: PairRole.provider,
    );
    final wb = dataBusRef.internalInterface as WishboneInterface;

    wb.cyc <= mmu.wbCyc;
    wb.stb <= mmu.wbStb;
    wb.we <= mmu.wbWe;
    wb.adr <= mmu.wbAdr;
    wb.datMosi <= mmu.wbDatMosi;
    wb.sel <= mmu.wbSel;
    wbAckExt <= wb.ack;
    wbDatMisoExt <= wb.datMiso;

    // Logic-analyzer bus taps: mirror the consumer-direction signals (ACK, read
    // data) to plain outputs for GPIO routing. These inputs cannot be read in
    // the parent without violating module hierarchy, so the core exposes them.
    if (busTap) {
      addOutput('bustap_ack') <= wb.ack;
      addOutput('bustap_datmiso', width: wbConfig.dataWidth) <= wb.datMiso;
      // Master-side control so a stuck transaction is visible: a hung load shows
      // cyc=stb=1, we=0, ack=0 held forever, with adr at the wedged address.
      addOutput('bustap_cyc') <= mmu.wbCyc;
      addOutput('bustap_stb') <= mmu.wbStb;
      addOutput('bustap_we') <= mmu.wbWe;
      addOutput('bustap_adr', width: wbConfig.addressWidth) <= mmu.wbAdr;
    }

    // Register file. Dual-commit (config.commitLanes > 1) adds a second write
    // port. Single-write-port storage can't take two writes/cycle, so the file
    // is split into one bank per write port; same-bank collisions are arbitrated
    // and back-pressured via the wr*_ready outputs.
    final numWritePorts = config.commitLanes;
    final dualCommit = numWritePorts > 1;
    String wrPort(int w, String s) =>
        numWritePorts == 1 ? 'wr_$s' : 'wr${w}_$s';

    final rs1Read = DataPortInterface(config.mxlen.size, 5);
    final rs2Read = DataPortInterface(config.mxlen.size, 5);
    final rdWrite = DataPortInterface(config.mxlen.size, 5);
    regWritePort = rdWrite;
    final rdWrite1 = dualCommit
        ? DataPortInterface(config.mxlen.size, 5)
        : null;

    regs = HarborRegisterFile(
      numEntries: 32,
      dataWidth: config.mxlen.size,
      // Dual-dispatch (4 read ports) is a follow-on; commit drives writes.
      numReadPorts: 2,
      numWritePorts: numWritePorts,
      numBanks: numWritePorts,
      writeBufferDepth: config.writeBufferDepth,
      target: target,
      forceReadLatency: config.regfileReadLatency,
      name: 'riscv_regfile',
    );
    addSubModule(regs);
    regs.input('clk').srcConnection! <= clk;
    regs.input('reset').srcConnection! <= reset;
    // While halted, the Debug Module borrows read/write port 0 to service
    // abstract register-access commands (the pipeline is frozen).
    regs.input('rd0_addr').srcConnection! <=
        (withDebug ? mux(dbgGprRead!, dbgGprIdx!, rs1Read.addr) : rs1Read.addr);
    regs.input('rd1_addr').srcConnection! <= rs2Read.addr;
    regs.input(wrPort(0, 'en')).srcConnection! <=
        (withDebug ? mux(dbgGprWrite!, Const(1), rdWrite.en) : rdWrite.en);
    regs.input(wrPort(0, 'addr')).srcConnection! <=
        (withDebug
            ? mux(dbgGprWrite!, dbgGprIdx!, rdWrite.addr)
            : rdWrite.addr);
    regs.input(wrPort(0, 'data')).srcConnection! <=
        (withDebug
            ? mux(dbgGprWrite!, dbgRegWdata!, rdWrite.data)
            : rdWrite.data);
    Logic? wr0Ready;
    Logic? wr1Ready;
    if (dualCommit) {
      regs.input(wrPort(1, 'en')).srcConnection! <= rdWrite1!.en;
      regs.input(wrPort(1, 'addr')).srcConnection! <= rdWrite1.addr;
      regs.input(wrPort(1, 'data')).srcConnection! <= rdWrite1.data;
      wr0Ready = regs.writeReady(0);
      wr1Ready = regs.writeReady(1);
      rdWrite1.done <= rdWrite1.en;
      rdWrite1.valid <= rdWrite1.en;
    }
    // Preserve the rohd_hcl semantics: read data is zero when the port is
    // disabled (and x0 reads zero, handled inside HarborRegisterFile).
    rs1Read.data <=
        mux(rs1Read.en, regs.rd0Data, Const(0, width: config.mxlen.size));
    // Abstract-command read result: dcsr, dpc, misa, a general CSR (borrowed
    // read port), or the GPR on read port 0. dcsr/dpc/misa are special-cased so
    // they serve even when the CSR file does not implement them as readable CSRs.
    if (withDebug) {
      // For a GPR access read port 0; for a non-special CSR read the borrowed
      // CSR port (dbgCsrData, null when the core has no CSR file).
      final gprOrCsr = dbgCsrData == null
          ? regs.rd0Data
          : mux(dbgIsGpr!, regs.rd0Data, dbgCsrData);
      output('debug_reg_rdata') <=
          mux(
            dbgIsDcsr!,
            debugDcsr!.zeroExtend(config.mxlen.size),
            mux(
              dbgIsMisa!,
              Const(config.isa.misaValue, width: config.mxlen.size),
              mux(dbgIsDpc!, debugDpc!, gprOrCsr),
            ),
          );
    }
    rs2Read.data <=
        mux(rs2Read.en, regs.rd1Data, Const(0, width: config.mxlen.size));
    // Read data is [regs.readLatency] cycles behind the address (0 for the
    // combinational/iCE40 negedge-EBR read, 1 for the ECP5 posedge-EBR read).
    // Delay done/valid by the same latency so the operand-read handshake latches
    // the data on the cycle it is valid. Writes are single-cycle, unaffected.
    Logic delayReadHandshake(Logic en, String name) {
      var s = en;
      for (var i = 0; i < regs.readLatency; i++) {
        final q = Logic(name: '${name}_q$i');
        Sequential(clk, [q < s]);
        s = q;
      }
      return s;
    }

    rs1Read.done <= delayReadHandshake(rs1Read.en, 'rs1RdDone');
    rs1Read.valid <= delayReadHandshake(rs1Read.en, 'rs1RdValid');
    rs2Read.done <= delayReadHandshake(rs2Read.en, 'rs2RdDone');
    rs2Read.valid <= delayReadHandshake(rs2Read.en, 'rs2RdValid');
    rdWrite.done <= rdWrite.en;
    rdWrite.valid <= rdWrite.en;

    // Interrupts.
    Logic externalPending = Const(0);
    for (final entry in srcIrqs.entries) {
      final sig = addInput(entry.key, entry.value);
      final anyFromThis = sig.or();
      externalPending = externalPending | anyFromThis;
    }

    // CSR file.
    final csrRead = DataPortInterface(config.mxlen.size, 12);
    final csrWrite = DataPortInterface(config.mxlen.size, 12);

    // Interface handed to the CSR file. Normally the pipeline's csrRead, but
    // while halted the Debug Module borrows the frozen read port: it presents
    // the debug regno (the CSR address) and routes the result back.
    final DataPortInterface csrReadCsr;
    if (dbgCsrData != null) {
      csrReadCsr = DataPortInterface(config.mxlen.size, 12);
      csrReadCsr.addr <= mux(dbgCsrSel!, dbgRegAddr12!, csrRead.addr);
      csrReadCsr.en <= mux(dbgCsrSel, Const(1), csrRead.en);
      // Feed the CSR read result back to the pipeline and to the debugger.
      csrRead.data <= csrReadCsr.data;
      csrRead.done <= csrReadCsr.done;
      csrRead.valid <= csrReadCsr.valid;
      dbgCsrData <= csrReadCsr.data;
    } else {
      csrReadCsr = csrRead;
    }

    // satp shadow register. The CsrTop backdoor read (csrs.satp) only reflects
    // the register during a write and reads X otherwise, so snapshot the
    // architectural satp write into a stable register the MMU walks against.
    // (satp has a full WARL mask, so the raw write data is the value.)
    final satpShadow = Logic(name: 'satpShadow', width: config.mxlen.size);
    if (config.mmu.hasPaging) {
      Sequential(clk, [
        If(
          reset,
          then: [satpShadow < 0],
          orElse: [
            If(
              csrWrite.en &
                  csrWrite.addr
                      .slice(11, 0)
                      .eq(Const(CsrAddress.satp.address, width: 12)) &
                  (virt == null ? Const(1) : ~virt),
              then: [satpShadow < csrWrite.data],
            ),
          ],
        ),
      ]);
    } else {
      satpShadow <= Const(0, width: config.mxlen.size);
    }

    // VS-stage page-table root for guest (virt=1) data accesses. Snapshotted
    // from HS-mode writes to vsatp, same shadow trick as satpShadow.
    final vsatpShadow = Logic(name: 'vsatpShadow', width: config.mxlen.size);
    if (config.hasHypervisor && config.mmu.hasPaging) {
      Sequential(clk, [
        If(
          reset,
          then: [vsatpShadow < 0],
          orElse: [
            If(
              csrWrite.en &
                  (csrWrite.addr
                          .slice(11, 0)
                          .eq(Const(CsrAddress.vsatp.address, width: 12)) |
                      (csrWrite.addr
                              .slice(11, 0)
                              .eq(Const(CsrAddress.satp.address, width: 12)) &
                          (virt ?? Const(0)))),
              then: [vsatpShadow < csrWrite.data],
            ),
          ],
        ),
      ]);
    } else {
      vsatpShadow <= Const(0, width: config.mxlen.size);
    }

    // G-stage root (hgatp), snapshotted from HS-mode writes. Same MODE/PPN
    // layout as satp. Feeds the MMU's two-stage walk when virt=1.
    final hgatpShadow = Logic(name: 'hgatpShadow', width: config.mxlen.size);
    if (config.hasHypervisor && config.mmu.hasPaging) {
      Sequential(clk, [
        If(
          reset,
          then: [hgatpShadow < 0],
          orElse: [
            If(
              csrWrite.en &
                  csrWrite.addr
                      .slice(11, 0)
                      .eq(Const(CsrAddress.hgatp.address, width: 12)),
              then: [hgatpShadow < csrWrite.data],
            ),
          ],
        ),
      ]);
    } else {
      hgatpShadow <= Const(0, width: config.mxlen.size);
    }

    // Trap save-state / xRET restore controls, driven from the pipeline's
    // retire-cycle outputs below (forward-declared so they can feed the CSR file
    // which is built before the pipeline).
    final xlen = config.mxlen.size;
    final csrTrapActive = Logic(name: 'csrTrapActive');
    final csrTrapTargetIsM = Logic(name: 'csrTrapTargetIsM');
    final csrTrapPc = Logic(name: 'csrTrapPc', width: xlen);
    final csrTrapCauseVal = Logic(name: 'csrTrapCauseVal', width: xlen);
    final csrTrapTval = Logic(name: 'csrTrapTval', width: xlen);
    final csrReturnActive = Logic(name: 'csrReturnActive');
    final csrReturnFromM = Logic(name: 'csrReturnFromM');
    // A trap delegated to VS-mode (virt stays 1, target vstvec, save to vs*).
    final csrTrapToVS = config.hasHypervisor
        ? Logic(name: 'csrTrapToVS')
        : null;

    final csrs = config.hasCsrs
        ? RiscVCsrFile(
            clk,
            reset,
            mode,
            mxlen: config.mxlen,
            misa: config.isa.misaValue,
            mvendorid: config.vendorId,
            marchid: config.archId,
            mimpid: config.impId,
            mhartid: config.hartId,
            rpipelineCap: config.rpipelineCap,
            externalPending: externalPending,
            hasSupervisor: config.hasSupervisor,
            hasUser: config.hasUser,
            hasHypervisor: config.hasHypervisor,
            hasStateen: config.hasStateen,
            hasPaging: config.mmu.hasPaging,
            hasMxr: config.mmu.hasMakeExecutableReadable,
            hasSum: config.mmu.hasSupervisorUserMemory,
            trapActive: csrTrapActive,
            trapTargetIsM: csrTrapTargetIsM,
            trapPc: csrTrapPc,
            trapCauseVal: csrTrapCauseVal,
            trapTval: csrTrapTval,
            returnActive: csrReturnActive,
            returnFromM: csrReturnFromM,
            virtInput: config.hasHypervisor ? virt : null,
            trapToVS: csrTrapToVS,
            csrRead: csrReadCsr,
            csrWrite: csrWrite,
          )
        : null;

    if (csrs != null && csrs.satp != null) {
      pagingMode <=
          (((csrs.satp! >>
                      Const(
                        config.mxlen.satpModeShift,
                        width: config.mxlen.size,
                      )) &
                  Const(config.mxlen.satpModeMask, width: config.mxlen.size)))
              .slice(pagingMode.width - 1, 0);
      pageTableAddress <=
          (csrs.satp! &
              Const(config.mxlen.satpPpnMask, width: config.mxlen.size));
    } else {
      pagingMode <= Const(0, width: pagingMode.width);
      pageTableAddress <= Const(0, width: config.mxlen.size);
    }

    // satp.MODE / root PPN for the MMU come from the stable shadow register.
    // In guest (virt=1) mode, data accesses translate through vsatp not HS satp.
    final effectiveSatp = guestAccessWire == null
        ? satpShadow
        : mux(guestAccessWire, vsatpShadow, satpShadow);
    satpModeWire <=
        ((effectiveSatp >>
                    Const(
                      config.mxlen.satpModeShift,
                      width: config.mxlen.size,
                    )) &
                Const(config.mxlen.satpModeMask, width: config.mxlen.size))
            .slice(3, 0);
    satpRootWire <=
        (effectiveSatp &
            Const(config.mxlen.satpPpnMask, width: config.mxlen.size));

    if (gModeWire != null) {
      gModeWire <=
          ((hgatpShadow >>
                      Const(
                        config.mxlen.satpModeShift,
                        width: config.mxlen.size,
                      )) &
                  Const(config.mxlen.satpModeMask, width: config.mxlen.size))
              .slice(3, 0);
      gRootWire! <=
          (hgatpShadow &
              Const(config.mxlen.satpPpnMask, width: config.mxlen.size));
    }

    if (csrs != null) {
      enableMxr <=
          ((csrs.mstatus >> 19) & Const(1, width: config.mxlen.size)).neq(0);
      enableSum <=
          ((csrs.mstatus >> 18) & Const(1, width: config.mxlen.size)).neq(0);
    }
    // DTLBFC bit (rpipelinectl[3]) -> MMU data-TLB priv-change flush.
    dtlbFlushOnPriv <= (csrs == null ? Const(0) : csrs.rpipelinectl[3]);

    // Microcode ROMs (optionally PATCHABLE at runtime via the rmicrocode* CSRs).
    // Parallel decode: the decode ROM packs `decodeLanes` pattern rows per word
    // (lane 0 in the low bits) so the dynamic decoder reads + compares that many
    // patterns per cycle, shortening its scan to ceil(patterns/lanes) cycles.
    // lanes==1 is the classic one-per-cycle ROM.
    final decodeLanes = config.microcodeDecodeLanes;
    final patternW = microcode.patternWidth;
    final decodeRowW = patternW * decodeLanes;
    final decodeWords = (microcode.map.length + decodeLanes - 1) ~/ decodeLanes;
    // Match the original count.bitLength convention (the RegisterFile/ROM index).
    final decodeIdxW = decodeWords.bitLength;
    // Pack: word w = pattern[w*lanes + l] << (l*patternW), padding the tail with
    // the last real pattern (a never-false extra: if the instruction matched it
    // the real lane matches first by priority, so no spurious hit).
    final rawPatterns = microcode.encodedPatterns;
    final packedPatterns = <BigInt>[
      for (var w = 0; w < decodeWords; w++)
        [
          for (var l = 0; l < decodeLanes; l++)
            rawPatterns[(w * decodeLanes + l).clamp(
                  0,
                  rawPatterns.length - 1,
                )] <<
                (l * patternW),
        ].reduce((a, b) => a | b),
    ];

    final microcodeDecodeRead = DataPortInterface(decodeRowW, decodeIdxW);
    final microcodeExecRead = DataPortInterface(
      microcode.mopWidth(config.mxlen),
      microcode.mopIndexWidth(config.mxlen),
    );

    final execRowW = microcode.mopWidth(config.mxlen);
    final execIdxW = microcode.mopIndexWidth(config.mxlen);

    // Runtime microcode update: a ROM row can be wider than XLEN, so the CPU
    // shifts the row in over rmicrocodedata (XLEN bits per push) and commits it
    // into the selected ROM. The rmicrocodectl strobes come from the csrWrite
    // write-pulse for that address, so each fires for one cycle and never
    // re-triggers. Built only when the core has CSRs and a microcode ROM.
    DataPortInterface? decodeWrite;
    DataPortInterface? execWrite;
    if (csrs != null && config.microcodeMode != MicrocodeMode.none) {
      final xlen = config.mxlen.size;
      final stagingW = decodeRowW > execRowW ? decodeRowW : execRowW;
      final staging = Logic(name: 'microcodeStaging', width: stagingW);

      final isCtl = csrWrite.addr.eq(
        Const(CsrAddress.rmicrocodectl.address, width: csrWrite.addr.width),
      );
      final pulse = csrWrite.en & isCtl;
      final push = pulse & csrWrite.data[0];
      final commit = pulse & csrWrite.data[1];
      final clear = pulse & csrWrite.data[2];

      final patchAddr = csrs.rmicrocodeaddr;
      final patchData = csrs.rmicrocodedata;
      // bit[XLEN-1] of the address selects the decode ROM (1) vs exec ROM (0).
      final targetDecode = patchAddr[xlen - 1];

      Sequential(clk, reset: reset, [
        If(
          clear,
          then: [staging < 0],
          orElse: [
            If(
              push,
              then: [
                staging < ((staging << xlen) | patchData.zeroExtend(stagingW)),
              ],
            ),
          ],
        ),
      ]);

      if (config.microcodeMode.onDecoder != MicrocodePipelineMode.none) {
        decodeWrite = DataPortInterface(decodeRowW, decodeIdxW);
        decodeWrite.en <= commit & targetDecode;
        decodeWrite.addr <= patchAddr.slice(decodeIdxW - 1, 0);
        decodeWrite.data <= staging.slice(decodeRowW - 1, 0);
      }
      if (config.microcodeMode.onExec != MicrocodePipelineMode.none) {
        execWrite = DataPortInterface(execRowW, execIdxW);
        execWrite.en <= commit & ~targetDecode;
        execWrite.addr <= patchAddr.slice(execIdxW - 1, 0);
        execWrite.data <= staging.slice(execRowW - 1, 0);
      }
    }

    if (config.microcodeMode.onDecoder != MicrocodePipelineMode.none) {
      // Decode pattern ROM (microcode.map.length x decodeRowW ~= 18k FF as a
      // resetValue RegisterFile). On ECP5 a DP16KD ROM (registered read),
      // elsewhere a flop ROM with a pipeline register so both paths have read
      // latency 1. done/valid lag `en` by 1 to match; the decoder holds its
      // address until `done`, so the registered read costs one fill cycle/probe.
      final useEbrRom =
          target is HarborFpgaTarget && target.vendor == HarborFpgaVendor.ecp5;
      final useXilinxRom =
          target is HarborFpgaTarget &&
          (target.vendor == HarborFpgaVendor.openXc7 ||
              target.vendor == HarborFpgaVendor.vivado);

      if (useEbrRom) {
        final rom = Ecp5InitRom(
          clk,
          contents: packedPatterns,
          width: decodeRowW,
          rdAddr: microcodeDecodeRead.addr,
          wrEn: decodeWrite?.en,
          wrAddr: decodeWrite?.addr,
          wrData: decodeWrite?.data,
          definitionName: 'RiverMicrocodeLookup',
        );
        microcodeDecodeRead.data <= rom.rdData;
      } else if (useXilinxRom) {
        // Xilinx: a behavioural BRAM-inferable ROM (synth_xilinx -> RAMB) so
        // the decode ROM does not explode into flops.
        final rom = InferredInitRom(
          clk,
          contents: packedPatterns,
          width: decodeRowW,
          rdAddr: microcodeDecodeRead.addr,
          wrEn: decodeWrite?.en,
          wrAddr: decodeWrite?.addr,
          wrData: decodeWrite?.data,
          definitionName: 'RiverMicrocodeLookup',
        );
        microcodeDecodeRead.data <= rom.rdData;
      } else {
        final decodeRaw = DataPortInterface(decodeRowW, decodeIdxW);
        decodeRaw.en <= microcodeDecodeRead.en;
        decodeRaw.addr <= microcodeDecodeRead.addr;
        RegisterFile(
          clk,
          reset,
          decodeWrite != null ? [wrapWriteForRegisterFile(decodeWrite)] : [],
          [wrapReadForRegisterFile(decodeRaw)],
          numEntries: decodeWords,
          resetValue: packedPatterns,
          definitionName: 'RiverMicrocodeLookup',
        );
        final decodeDataReg = Logic(
          name: 'microcodeDecodeDataReg',
          width: decodeRowW,
        );
        Sequential(clk, [decodeDataReg < decodeRaw.data]);
        microcodeDecodeRead.data <= decodeDataReg;
      }

      final decodeHsReg = Logic(name: 'microcodeDecodeHsReg');
      Sequential(clk, reset: reset, [decodeHsReg < microcodeDecodeRead.en]);
      microcodeDecodeRead.done <= microcodeDecodeRead.en & decodeHsReg;
      microcodeDecodeRead.valid <= microcodeDecodeRead.en & decodeHsReg;
    }

    if (config.microcodeMode.onExec != MicrocodePipelineMode.none) {
      final mops = microcode.encodedMops(config.mxlen);

      // Pipeline the exec ROM read: the addr -> ROM -> funct-decode + ALU-tree
      // path is the microcode Fmax bottleneck. Register the ROM data so
      // addr->ROM and ROM-data->ALU are separate stages, and delay the read
      // handshake to match (one extra read-latency cycle; the exec FSM already
      // stalls on done/valid). valid is gated by `en` so the registered
      // handshake does not leave a stale valid high after en deasserts.
      // The exec ROM is the largest memory in the core (mops.length x execRowW):
      // as a flop RegisterFile ~94k FF, 4x the whole LFE5U-25F. On ECP5 it MUST
      // be EBR (DP16KD, contents baked in via INITVAL); port B's registered read
      // IS the pipeline stage (1-cycle, matching the sim combinational-ROM +
      // execDataReg), the update-CSR write goes to port A. Sim has no DP16KD
      // model, so non-ECP5 targets keep the flop ROM (microcode via resetValue).
      final useEbrRom =
          target is HarborFpgaTarget && target.vendor == HarborFpgaVendor.ecp5;
      final useXilinxRom =
          target is HarborFpgaTarget &&
          (target.vendor == HarborFpgaVendor.openXc7 ||
              target.vendor == HarborFpgaVendor.vivado);

      if (useEbrRom) {
        final rom = Ecp5InitRom(
          clk,
          contents: mops,
          width: execRowW,
          rdAddr: microcodeExecRead.addr,
          wrEn: execWrite?.en,
          wrAddr: execWrite?.addr,
          wrData: execWrite?.data,
          definitionName: 'RiverMicrocodeOperations',
        );
        microcodeExecRead.data <= rom.rdData;
      } else if (useXilinxRom) {
        // Xilinx: BRAM-inferable ROM instead of the ~94k-FF flop RegisterFile.
        final rom = InferredInitRom(
          clk,
          contents: mops,
          width: execRowW,
          rdAddr: microcodeExecRead.addr,
          wrEn: execWrite?.en,
          wrAddr: execWrite?.addr,
          wrData: execWrite?.data,
          definitionName: 'RiverMicrocodeOperations',
        );
        microcodeExecRead.data <= rom.rdData;
      } else {
        final execRaw = DataPortInterface(execRowW, execIdxW);
        execRaw.en <= microcodeExecRead.en;
        execRaw.addr <= microcodeExecRead.addr;

        RegisterFile(
          clk,
          reset,
          execWrite != null ? [wrapWriteForRegisterFile(execWrite)] : [],
          [wrapReadForRegisterFile(execRaw)],
          numEntries: mops.length,
          resetValue: mops,
          definitionName: 'RiverMicrocodeOperations',
        );

        final execDataReg = Logic(
          name: 'microcodeExecDataReg',
          width: execRowW,
        );
        Sequential(clk, [execDataReg < execRaw.data]);
        microcodeExecRead.data <= execDataReg;
      }

      final execHsReg = Logic(name: 'microcodeExecHsReg');
      Sequential(clk, reset: reset, [execHsReg < microcodeExecRead.en]);
      microcodeExecRead.done <= microcodeExecRead.en & execHsReg;
      microcodeExecRead.valid <= microcodeExecRead.en & execHsReg;
    }

    // Multiple-outstanding fetch port (decoupled, latency-agnostic). When
    // fetchOutstanding > 1, fetch runs over a decoupled request/response port
    // the PipelinedFetchUnit drives, keeping several reads in flight (the
    // unified bus/icache is single-outstanding). Exposed at the core boundary so
    // the system can attach any fetch memory (fixed-latency BRAM/TCM or a
    // variable-latency DRAM/cache/AXI source) driving rsp_valid/req_ready; the
    // core makes no latency assumption.
    FetchReadInterface? fetchReadPort;
    if (config.fetchOutstanding > 1) {
      // Instructions are 32-bit, so the fetch port carries a 32-bit word with an
      // mxlen-wide address (one instruction per fetch, no 64-bit packing).
      final aw = config.mxlen.size;
      addOutput('fetchReq_valid');
      addOutput('fetchReq_addr', width: aw);
      createPort('fetchReq_ready', PortDirection.input);
      createPort('fetchRsp_valid', PortDirection.input);
      createPort('fetchRsp_data', PortDirection.input, width: 32);

      fetchReadPort = FetchReadInterface(32, aw);
      output('fetchReq_valid') <= fetchReadPort.reqValid;
      output('fetchReq_addr') <= fetchReadPort.reqAddr;
      fetchReadPort.reqReady <= input('fetchReq_ready');
      fetchReadPort.rspValid <= input('fetchRsp_valid');
      fetchReadPort.rspData <= input('fetchRsp_data');
    }

    // Backdoor prf seed: when prfSeedMode is asserted (frozen seed window), an
    // architectural regWritePort write also seeds the OoO physical regfile at
    // the same (arch == phys under the reset-identity rename map) index.
    final prfSeedModeIn = prfSeedMode == null
        ? null
        : addInput('prfSeedMode', prfSeedMode);

    // Pipeline.
    pipeline = RiverPipeline(
      clk,
      reset,
      pipelineEnable,
      sp,
      pc,
      mode,
      config.hasCsrs ? csrRead : null,
      config.hasCsrs ? csrWrite : null,
      pipeFetchRead,
      pipeExecRead,
      pipeExecWrite,
      rs1Read,
      rs2Read,
      rdWrite,
      config.microcodeMode.onDecoder != MicrocodePipelineMode.none
          ? microcodeDecodeRead
          : null,
      config.microcodeMode.onExec != MicrocodePipelineMode.none
          ? microcodeExecRead
          : null,
      useOoO: config.executionMode == ExecutionMode.outOfOrder,
      useMixedDecoders:
          config.microcodeMode.onDecoder == MicrocodePipelineMode.inParallel,
      useMixedExecution:
          config.microcodeMode.onExec == MicrocodePipelineMode.inParallel,
      microcode: microcode,
      mxlen: config.mxlen,
      vlen: config.vlen,
      hasSupervisor: config.hasSupervisor,
      hasUser: config.hasUser,
      hasCompressed: config.extensions.any((e) => e.name == 'C'),
      mideleg: csrs?.mideleg,
      medeleg: csrs?.medeleg,
      mtvec: csrs?.mtvec,
      stvec: csrs?.stvec,
      mepc: csrs?.mepc,
      sepc: (csrs != null && config.hasSupervisor) ? csrs.sepc : null,
      virt: virt,
      mstateen0Se0: csrs?.mstateen0Se0,
      hstateen0Se0: csrs?.hstateen0Se0,
      memFaultGuest: config.hasHypervisor ? mmu.dportFaultGuest : null,
      specCtl: csrs?.rpipelinectl.getRange(0, 4),
      prfSeedEn: prfSeedModeIn == null ? null : (prfSeedModeIn & rdWrite.en),
      prfSeedAddr: prfSeedModeIn == null ? null : rdWrite.addr,
      prfSeedData: prfSeedModeIn == null ? null : rdWrite.data,
      ifetchFault: (config.mmu.hasPaging && !useICache)
          ? mmu.ifetchFault
          : null,
      rdWrite1: rdWrite1,
      wr0Ready: wr0Ready,
      wr1Ready: wr1Ready,
      speculative: config.speculativeFetch,
      dualDispatch: dualDispatch,
      prefetchFetch: config.prefetchFetch,
      prefetchDepth: config.prefetchDepth,
      fetchOutstanding: config.fetchOutstanding,
      fetchReadPort: fetchReadPort,
      branchPredictor: config.branchPredictor,
      loadStoreQueue: config.loadStoreQueue,
      robDepth: config.robDepth,
      storeQueueDepth: config.storeQueueDepth,
      loadQueueDepth: config.loadQueueDepth,
      memFetchRead1: pipeFetchRead1,
      staticInstructions: staticInstructions,
    );

    // Flush the instruction cache on fence.i (the pipeline's fence signal).
    icFlush <= pipeline.fence;
    mmuTlbFlush <= pipeline.fence;
    // Flush the D-cache on the same fence. It is virtually addressed, so a fence
    // drops any line a translation change could alias, keeping paged-mode data
    // coherent without an sfence path (conservative on creek where VA == PA).
    if (useDCache) dFlush <= pipeline.fence;

    // An access is guest-translated when the core is virtualized OR the current
    // access is an HLV/HSV (memGuest). Drives the MMU's VS/G-stage routing.
    if (guestAccessWire != null) {
      guestAccessWire <= virt! | pipeline.memGuest;
    }

    // Drive the CSR file's trap/return controls from the pipeline retire-cycle
    // outputs. `committing` matches the PC-latch gate so each event fires once.
    if (csrs != null) {
      // One-shot commit: pipelineEnable is 1 only on the first done cycle.
      final committing = ~interruptHold & pipeline.done & pipelineEnable;
      // An ebreak commits as a breakpoint trap (cause 3). If dcsr.ebreak* is set
      // for the current privilege, redirect it to Debug Mode: suppress the
      // architectural trap and let the halt FSM latch dpc/cause.
      Logic trapSuppress = Const(0);
      if (withDebug) {
        final ebreakForMode =
            (mode.eq(Const(PrivilegeMode.machine.id, width: 3)) &
                debugDcsr![15]) |
            (mode.eq(Const(PrivilegeMode.supervisor.id, width: 3)) &
                debugDcsr[13]) |
            (mode.eq(Const(PrivilegeMode.user.id, width: 3)) & debugDcsr[12]);
        ebreakDebug! <=
            committing &
                pipeline.trap &
                pipeline.trapCause.eq(Const(3, width: 6)) &
                ebreakForMode;
        trapSuppress = ebreakDebug;
      }
      csrTrapActive <= committing & pipeline.trap & ~trapSuppress;
      csrTrapTargetIsM <=
          pipeline.nextMode.eq(Const(PrivilegeMode.machine.id, width: 3));
      csrTrapPc <= pipeline.trapEpc;
      csrTrapCauseVal <= pipeline.trapCause.zeroExtend(xlen);
      csrTrapTval <= pipeline.trapTval;
      csrReturnActive <= committing & pipeline.isReturn;
      csrReturnFromM <= pipeline.returnLevel.eq(Const(3, width: 3));
      if (csrTrapToVS != null) {
        // exec already routed this trap to S (medeleg-delegated); upgrade to VS
        // when virtualized and hedeleg further delegates this cause.
        csrTrapToVS <=
            committing &
                pipeline.trap &
                virt! &
                pipeline.nextMode.eq(
                  Const(PrivilegeMode.supervisor.id, width: 3),
                ) &
                csrs.hedeleg![pipeline.trapCause];
      }
    } else {
      csrTrapActive <= Const(0);
      csrTrapTargetIsM <= Const(0);
      csrTrapPc <= Const(0, width: xlen);
      csrTrapCauseVal <= Const(0, width: xlen);
      csrTrapTval <= Const(0, width: xlen);
      csrReturnActive <= Const(0);
      csrReturnFromM <= Const(0);
    }

    // xRET PC/mode restore values (read combinationally from the CSR backdoor).
    final retPc = csrs == null
        ? pipeline.nextPc
        : mux(
            csrReturnFromM,
            csrs.mepc,
            config.hasSupervisor ? csrs.sepc : Const(0, width: xlen),
          );
    final retMode = csrs == null
        ? pipeline.nextMode
        : mux(
            csrReturnFromM,
            // MPP = mstatus[12:11]
            csrs.mstatus.slice(12, 11).zeroExtend(3),
            // SPP = sstatus[8] ? supervisor : user
            config.hasSupervisor
                ? mux(
                    csrs.sstatus![8],
                    Const(PrivilegeMode.supervisor.id, width: 3),
                    Const(PrivilegeMode.user.id, width: 3),
                  )
                : Const(PrivilegeMode.machine.id, width: 3),
          );

    // V-bit restore on xRET: MRET enters virt iff MPP!=M and mstatus.MPV; an
    // HS-mode SRET (virt=0) enters the guest iff hstatus.SPV (a guest-mode SRET
    // keeps virt=1). Trap entry clears virt.
    final retVirt = (csrs == null || !config.hasHypervisor)
        ? Const(0)
        : mux(
            csrReturnFromM,
            retMode.neq(Const(PrivilegeMode.machine.id, width: 3)) &
                csrs.mstatus[39],
            mux(virt!, Const(1), csrs.hstatus![7]),
          );

    // VS-delegated trap vector (vstvec base, direct mode). The trap stays in
    // VS-mode (virt=1) and saves to vs* (handled in the CSR file).
    final vsTrapPc = (csrTrapToVS == null)
        ? Const(0, width: xlen)
        : (csrs!.vstvec! & ~Const(0x3, width: xlen));

    // Core state machine. The normal (non-halted) advance body, captured so
    // debug-halt can gate it.
    final coreBody = <Conditional>[
      If(
        interruptHold & externalPending,
        then: [interruptHold < 0, pipelineEnable < 1, fence < 0],
      ),
      If(
        ~interruptHold,
        then: [
          // Commit exactly once: pipeline.done can stay asserted for several
          // drain cycles, but pipelineEnable is 1 only on the first done cycle.
          // Critical for xRET/trap where the commit mutates CSR state (mstatus
          // pop); a second fire would read the popped value and corrupt the mode.
          If(
            pipeline.done & pipelineEnable,
            then: [
              // On xRET, restore PC/mode from {m,s}epc/{m,s}status; the CSR
              // file pops the status stack in parallel. Otherwise advance
              // normally (doTrap already redirected nextPc to tvec).
              If(
                pipeline.isReturn,
                then: [
                  pc < retPc,
                  mode < retMode,
                  if (virt != null) virt < retVirt,
                ],
                orElse: [
                  // A trap delegated to VS-mode targets vstvec and STAYS
                  // virtualized; all other traps go to HS/M and clear virt.
                  pc <
                      (csrTrapToVS == null
                          ? pipeline.nextPc
                          : mux(csrTrapToVS, vsTrapPc, pipeline.nextPc)),
                  mode < pipeline.nextMode,
                  if (virt != null)
                    virt < mux(pipeline.trap, csrTrapToVS ?? Const(0), virt),
                ],
              ),
              sp < pipeline.nextSp,
              interruptHold < pipeline.interruptHold,
              fence < pipeline.fence,
              // Lockstep commits once then drops enable to force a re-fetch.
              // Speculative fetch keeps the pipeline enabled and self-sequences,
              // so the commit fires every `done` cycle (distinct instructions).
              if (!config.speculativeFetch) pipelineEnable < 0,
            ],
          ),
          // Re-enable the pipeline once `done` drops (the next fetch is
          // underway); do not re-enable during the drain cycles.
          If(~pipeline.done, then: [pipelineEnable < 1, fence < 0]),
        ],
        orElse: [pipelineEnable < 0, fence < 0],
      ),
    ];

    Sequential(clk, [
      If(
        reset,
        then: [
          pipelineEnable < 0,
          pc < config.resetVector,
          sp < 0,
          // RISC-V resets to machine mode (PrivilegeMode.machine == 3).
          mode < PrivilegeMode.machine.id,
          if (virt != null) virt < 0,
          fence < 0,
          interruptHold < 0,
          if (withDebug) debugHalted! < 0,
          if (withDebug) debugDpc! < config.resetVector,
          // dcsr reset: debugver=4 (0.13.2), prv=3 (machine), cause=0.
          if (withDebug) debugDcsr! < Const(0x40000003, width: 32),
        ],
        orElse: withDebug
            ? [
                // While halted, freeze the pipeline and hold the PC; resume on
                // the debugger's request. Otherwise enter debug mode at the
                // next instruction boundary on haltreq, latching dpc.
                If(
                  debugHalted!,
                  then: [
                    pipelineEnable < 0,
                    // A debugger may rewrite dpc to redirect where we resume.
                    If(
                      input('debug_reg_write') & dbgIsDpc!,
                      then: [debugDpc! < dbgRegWdata!],
                    ),
                    // A debugger may write dcsr (ebreak/step/prv bits). debugver
                    // (31:28) is read-only and cause (8:6) is hardware-set, so
                    // force the former and preserve the latter on every write.
                    If(
                      input('debug_reg_write') & dbgIsDcsr!,
                      then: [
                        debugDcsr! <
                            (dbgRegWdata.getRange(0, 32) &
                                    Const(0x0FFFFE3F, width: 32)) |
                                Const(0x40000000, width: 32) |
                                (debugDcsr & Const(0x000001C0, width: 32)),
                      ],
                    ),
                    If(resumeReqIn!, then: [debugHalted < 0, pc < debugDpc]),
                  ],
                  orElse: [
                    If(
                      haltReqIn!,
                      then: [
                        debugHalted < 1,
                        pipelineEnable < 0,
                        debugDpc < pc,
                        // Halt cause = 3 (haltreq); keep the other dcsr bits.
                        debugDcsr <
                            (debugDcsr & Const(0xFFFFFE3F, width: 32)) |
                                Const(3 << 6, width: 32),
                      ],
                      orElse: [
                        If(
                          ebreakDebug!,
                          then: [
                            // ebreak entered Debug Mode: freeze at the ebreak,
                            // latch its pc into dpc, cause = 1 (ebreak).
                            debugHalted < 1,
                            pipelineEnable < 0,
                            debugDpc < pipeline.trapEpc,
                            debugDcsr <
                                (debugDcsr & Const(0xFFFFFE3F, width: 32)) |
                                    Const(1 << 6, width: 32),
                          ],
                          orElse: coreBody,
                        ),
                      ],
                    ),
                  ],
                ),
              ]
            : coreBody,
      ),
    ]);

    // Expose the V-bit for observability (no behavioral effect until VS-mode /
    // two-stage translation consume it).
    if (virt != null) {
      addOutput('virt') <= virt;
    }
  }
}
