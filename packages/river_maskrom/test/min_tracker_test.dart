import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:river_adl/river_adl.dart';
import 'package:test/test.dart';

/// Isolates the min-residue tracker pattern the DDR sweeps use (slt/beq/latch).
/// This is the recurring "tracker never updates / latches the first combo" bug.
/// A tiny ADL program walks a residue array in SRAM, runs the EXACT
/// `x12 = slt(res, min); beq x12,x0,skip; min=res; idx=i` pattern, and writes
/// (min, idx) to SRAM. We inject a sequence whose true minimum is NOT the first
/// element and assert the tracker finds it.
class _MinTracker extends Module {
  _MinTracker({
    required this.isa,
    required this.arrBase,
    required this.outBase,
    required this.n,
  });
  @override
  final RiscVIsaConfig isa;
  final int arrBase;
  final int outBase;
  final int n;

  void emit() {
    // x20 = min (init 0x1000), x21 = best idx, x25 = i (0..n-1).
    register(Register.x20).bind(li(0x1000));
    register(Register.x21).bind(li(0));
    register(Register.x25).bind(li(0)); // i
    final top = label('top');
    // load res = mem[arrBase + i*4]; addr = arrBase + (i<<2).
    register(Register.x11).bind(slli(register(Register.x25), 2)); // i*4
    register(Register.x10).bind(li(arrBase));
    register(
      Register.x10,
    ).bind(add(register(Register.x10), register(Register.x11)));
    register(Register.x4).bind(lw(register(Register.x10))); // res
    register(Register.x11).bind(andi(register(Register.x4), 0xFFF)); // residue
    // min-tracker: if residue < min, latch.
    final skip = label('skip');
    register(
      Register.x12,
    ).bind(slt(register(Register.x11), register(Register.x20)));
    beq(register(Register.x12), register(Register.x0), skip);
    register(Register.x20).bind(mv(register(Register.x11))); // min = residue
    register(Register.x21).bind(mv(register(Register.x25))); // idx = i
    placeLabel(skip);
    // i++; while i < n.
    register(Register.x25).bind(addi(register(Register.x25), 1));
    register(Register.x11).bind(li(n));
    blt(register(Register.x25), register(Register.x11), top);
    // store min -> out[0], idx -> out[1].
    register(Register.x10).bind(li(outBase));
    sw(register(Register.x10), register(Register.x20));
    register(Register.x10).bind(li(outBase + 4));
    sw(register(Register.x10), register(Register.x21));
    // spin.
    final done = label('done');
    jal(done);
  }
}

void main() {
  test(
    'min-residue tracker finds the global minimum (not the first element)',
    () async {
      const romBase = 0x70000000;
      const ramBase = 0x80000000;
      const arrBase = ramBase + 0x1000;
      const outBase = ramBase + 0x2000;

      // Residue sequence: first element is large (0xFCE, the observed false min),
      // the TRUE minimum (0x002) is at index 5, with smaller values before and
      // after to exercise descent + non-update.
      final residues = [0xFCE, 0x800, 0x400, 0xFCE, 0x100, 0x002, 0x050, 0x900];
      final trueMin = residues.reduce((a, b) => a < b ? a : b); // 0x002
      final trueIdx = residues.indexOf(trueMin); // 5

      final config = RiverCoreConfigV1.micro(
        mmu: HarborMmuConfig(
          mxlen: RiscVMxlen.rv64,
          pagingModes: const [RiscVPagingMode.bare],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
        ),
        interrupts: [],
        clock: const HarborClockConfig(
          name: 'test',
          rate: HarborFixedClockRate(10000),
        ),
        resetVector: romBase,
      );

      final prog = _MinTracker(
        isa: config.isa,
        arrBase: arrBase,
        outBase: outBase,
        n: residues.length,
      );
      prog.emit();
      await prog.build();
      final romBytes = prog.generateBinary();

      final romMem = Sram(
        RiverDevice(
          name: 'rom',
          compatible: 'river,sram',
          range: BusAddressRange(romBase, 0x10000),
          clockFrequency: 10000,
        ),
      );
      final sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(ramBase, 0x10000),
          clockFrequency: 10000,
        ),
      );
      for (var i = 0; i < romBytes.length; i++) {
        romMem.data[i] = romBytes[i];
      }
      // Seed the residue array into SRAM.
      for (var i = 0; i < residues.length; i++) {
        final off = (arrBase - ramBase) + i * 4;
        sram.data[off] = residues[i] & 0xff;
        sram.data[off + 1] = (residues[i] >> 8) & 0xff;
        sram.data[off + 2] = (residues[i] >> 16) & 0xff;
        sram.data[off + 3] = (residues[i] >> 24) & 0xff;
      }

      final core = RiverCore(
        config,
        memDevices: Map.fromEntries([romMem.mem!, sram.mem!]),
      );

      var pc = romBase;
      for (var i = 0; i < 200000; i++) {
        final instr = await core.fetch(pc);
        final next = await core.cycle(pc, instr);
        if (next == pc) break;
        pc = next;
      }

      int read32(int addr) {
        final off = addr - ramBase;
        return sram.data[off] |
            (sram.data[off + 1] << 8) |
            (sram.data[off + 2] << 16) |
            (sram.data[off + 3] << 24);
      }

      final gotMin = read32(outBase);
      final gotIdx = read32(outBase + 4);
      expect(
        gotMin,
        equals(trueMin),
        reason:
            'tracker latched min=0x${gotMin.toRadixString(16)} but the true '
            'minimum is 0x${trueMin.toRadixString(16)} - the min-tracker never '
            'descended past the first/large element (the recurring sweep bug)',
      );
      expect(
        gotIdx,
        equals(trueIdx),
        reason:
            'tracker latched idx=$gotIdx but the true minimum is at index '
            '$trueIdx',
      );
    },
  );
}
