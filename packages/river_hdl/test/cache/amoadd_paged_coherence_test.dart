import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Paged repro attempt for the delta ticket-lock corruption. The M-mode HW
/// amoadd hammer loses nothing, so the failing variable is PAGING: the kernel
/// runs S-mode/Sv39 and delta's MMU has tlbLevels:[] (page-walks EVERY access),
/// so the amoadd's read phase and write phase each translate the SAME VA
/// independently. This runs the amoadd loop at a VIRTUAL address (0x80001000)
/// that a 1GB identity leaf maps to DRAM, so every amoadd traverses the MMU +
/// D-cache, and requires no increment to be lost.
///
///   M-mode: csrw satp (Sv39, root@0x2000), sfence, mepc=loop, MPP=S, mret
///   S-mode loop: amoadd.w.aqrl x6,x7,(x5)  ; addi x8,-1 ; bnez ; park
///   satp root: [0]=1GB identity leaf (code/PT), [2]=1GB identity leaf (DRAM)
void main() {
  test(
    'paged amoadd loop through the MMU never loses an increment',
    timeout: Timeout(Duration(minutes: 8)),
    () async {
      const n = 4;
      const amo =
          (0x03 << 25) |
          (7 << 20) |
          (5 << 15) |
          (2 << 12) |
          (6 << 7) |
          0x2f; // amoadd.w.aqrl x6,x7,(x5)
      final words = <int, int>{
        0x00: 0x18051073, // csrw satp, x10
        0x04: 0x12000073, // sfence.vma
        0x08: 0x34159073, // csrw mepc, x11
        0x0c: 0x30061073, // csrw mstatus, x12  (MPP=S)
        0x10: 0x30200073, // mret -> S-mode @ 0x40
        0x40: amo, // loop:
        0x44: 0xfff40413, // addi x8, x8, -1
        0x48: 0xfe041ce3, // bnez x8, -8  (-> 0x40)
        0x4c: 0x0000006f, // park
      };

      // Sv39 root page table @ PA 0x2000. 1GB leaves, V|R|W|X|A|D = 0xCF.
      //   root[0] (VA 0..0x3fffffff  -> PA identity)  : code + page table
      //   root[2] (VA 0x80000000..   -> PA identity)  : DRAM (the lock)
      final bytes = <int, int>{}; // byte address -> byte
      void putWord(int addr, int w) {
        for (var b = 0; b < 4; b++) {
          bytes[addr + b] = (w >> (b * 8)) & 0xFF;
        }
      }

      void putDword(int addr, int lo, int hi) {
        putWord(addr, lo);
        putWord(addr + 4, hi);
      }

      words.forEach(putWord);
      putDword(
        0x2000,
        0x000000CF,
        0x00000000,
      ); // root[0]  code identity (VA 0..1G)
      // root[510] (VA 0xffffffff80000000.. -> PA 0x80000000, 1GB leaf): the kernel
      // maps its high VA to a lower DRAM PA, so the VIVT D-cache tags a high VA
      // while memory sits at a low PA. This is the untested atomic condition.
      putDword(0x2000 + 510 * 8, 0x200000CF, 0x00000000);

      final maxA = bytes.keys.reduce((a, b) => a > b ? a : b);
      final sb = StringBuffer('@0\n');
      for (var a = 0; a <= maxA + 1; a++) {
        sb.write((bytes[a] ?? 0).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }

      await coreTest(
        sb.toString(),
        {Register.x6: n - 1, Register.x8: 0},
        RiverCoreConfigV1.full(
          interrupts: [],
          mmu: HarborMmuConfig(
            mxlen: RiscVMxlen.rv64,
            pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
            tlbLevels: const [],
            pmp: HarborPmpConfig.none,
          ),
          clock: const HarborClockConfig(
            name: 'sysclk',
            rate: HarborFixedClockRate(48000000),
          ),
        ),
        initRegisters: {
          Register.x10: 0x8000000000000002, // satp: Sv39, root PPN 0x2
          Register.x11: 0x40, // mepc = loop start
          Register.x12: 0x800, // mstatus MPP = S
          Register.x5: 0xffffffff80001000, // high kernel VA -> PA 0x80001000
          Register.x7: 1, // increment
          Register.x8: n, // count
        },
        memStates: {0x80001000: n},
        nextPc: 0x4c,
      );
    },
  );
}
