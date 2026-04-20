import 'package:river/river.dart';
import 'package:test/test.dart';

void main() {
  group('RiverSoCConfig', () {
    test('getDevice finds by name', () {
      final config = RiverSoCConfig(
        devices: [
          const RiverDevice(
            name: 'flash',
            compatible: 'river,flash',
            range: BusAddressRange(0x20000000, 0x1000000),
          ),
          const RiverDevice(
            name: 'sram',
            compatible: 'river,sram',
            range: BusAddressRange(0x80000000, 0x100000),
          ),
        ],
      );

      expect(config.getDevice('flash'), isNotNull);
      expect(config.getDevice('flash')!.range!.start, 0x20000000);
      expect(config.getDevice('missing'), isNull);
    });

    test('getCore finds by hart ID', () {
      final sysclk = HarborClockConfig(
        name: 'sysclk',
        rate: HarborFixedClockRate(48000000),
      );

      final config = RiverSoCConfig(
        cores: [
          RiverCoreConfigV1.nano(
            mmu: HarborMmuConfig(
              mxlen: RiscVMxlen.rv32,
              pagingModes: const [RiscVPagingMode.bare],
              tlbLevels: const [],
              pmp: HarborPmpConfig.none,
            ),
            interrupts: [],
            clock: sysclk,
            resetVector: 0x20000000,
          ),
        ],
      );

      expect(config.getCore(0), isNotNull);
      expect(config.getCore(0)!.resetVector, 0x20000000);
      expect(config.getCore(1), isNull);
    });
  });

  group('RiverCoreConfig validation', () {
    final sysclk = HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    );
    final mmu = HarborMmuConfig(
      mxlen: RiscVMxlen.rv32,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    );

    test('defaults to in-order single-issue', () {
      final c = RiverCoreConfigV1.nano(mmu: mmu, interrupts: [], clock: sysclk);
      expect(c.executionMode, ExecutionMode.inOrder);
      expect(c.issueWidth, IssueWidth.single);
      expect(c.issueWidth.lanes, 1);
    });

    test('dual-issue with in-order throws ArgumentError', () {
      expect(
        () => RiverCoreConfig(
          clock: sysclk,
          mxlen: RiscVMxlen.rv32,
          extensions: const [],
          interrupts: const [],
          mmu: mmu,
          type: RiverCoreType.mcu,
          executionMode: ExecutionMode.inOrder,
          issueWidth: IssueWidth.dual,
        ),
        throwsArgumentError,
      );
    });

    test('dual-issue with out-of-order + speculative is accepted', () {
      expect(
        () => RiverCoreConfig(
          clock: sysclk,
          mxlen: RiscVMxlen.rv32,
          extensions: const [],
          interrupts: const [],
          mmu: mmu,
          type: RiverCoreType.mcu,
          executionMode: ExecutionMode.outOfOrder,
          speculativeFetch: true,
          issueWidth: IssueWidth.dual,
        ),
        returnsNormally,
      );
    });

    test('dual-issue without speculative fetch throws ArgumentError', () {
      expect(
        () => RiverCoreConfig(
          clock: sysclk,
          mxlen: RiscVMxlen.rv32,
          extensions: const [],
          interrupts: const [],
          mmu: mmu,
          type: RiverCoreType.mcu,
          executionMode: ExecutionMode.outOfOrder,
          issueWidth: IssueWidth.dual,
        ),
        throwsArgumentError,
      );
    });

    test('threads < 1 throws ArgumentError', () {
      expect(
        () => RiverCoreConfig(
          clock: sysclk,
          mxlen: RiscVMxlen.rv32,
          extensions: const [],
          interrupts: const [],
          mmu: mmu,
          type: RiverCoreType.mcu,
          threads: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('RVA22 profile', () {
    final sysclk = HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    );
    final config = RiverCoreConfig(
      mxlen: RiscVMxlen.rv64,
      extensions: kRva22S64Extensions,
      type: RiverCoreType.general,
      mmu: HarborMmuConfig(
        mxlen: RiscVMxlen.rv64,
        pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
        tlbLevels: const [],
        pmp: HarborPmpConfig.none,
      ),
      interrupts: [],
      clock: sysclk,
    );
    final names = config.extensions.map((e) => e.name).toSet();

    test('is RV64', () {
      expect(config.mxlen, RiscVMxlen.rv64);
    });

    // RVA22U64 mandatory: RV64GC + counters/hint/bitmanip/cache-management.
    const u64 = [
      'M',
      'A',
      'F',
      'D',
      'C',
      'Zicsr',
      'Zifencei',
      'Zicntr',
      'Zihpm',
      'Zihintpause',
      'Zba',
      'Zbb',
      'Zbs',
      'Zicbom',
      'Zicbop',
      'Zicboz',
      'Zic64b',
      'Za64rs',
      'Ziccif',
      'Ziccrse',
      'Ziccamoa',
      'Zicclsm',
    ];
    for (final ext in u64) {
      test('U64 mandatory: $ext present', () {
        expect(names, contains(ext));
      });
    }

    // RVA22S64 mandatory supervisor additions.
    const s64 = ['Priv', 'Svbare', 'Svade', 'Svinval', 'Svnapot', 'Svpbmt'];
    for (final ext in s64) {
      test('S64 mandatory: $ext present', () {
        expect(names, contains(ext));
      });
    }
  });

  group('RVA23 profile', () {
    final config = RiverCoreConfig(
      mxlen: RiscVMxlen.rv64,
      extensions: kRva23S64Extensions,
      type: RiverCoreType.general,
      mmu: HarborMmuConfig(
        mxlen: RiscVMxlen.rv64,
        pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
        tlbLevels: const [],
        pmp: HarborPmpConfig.none,
      ),
      interrupts: [],
      clock: HarborClockConfig(
        name: 'sysclk',
        rate: HarborFixedClockRate(48000000),
      ),
    );
    final names = config.extensions.map((e) => e.name).toSet();

    // RVA23 additions over RVA22 that Harbor expresses today (Zacas/Svadu/
    // state-enable are documented gaps, not yet in Harbor).
    const added = [
      'V',
      'Zicond',
      'Zimop',
      'Zcmop',
      'Zcb',
      'Zfa',
      'Zawrs',
      'Zihintntl',
      'Zkt',
      'Zfhmin',
      'Zvfhmin',
      'Zvbb',
      'Zvkt',
      'Sstc',
      'Sscofpmf',
    ];
    for (final ext in added) {
      test('RVA23 adds: $ext present', () {
        expect(names, contains(ext));
      });
    }

    test('still includes the RVA22 base (e.g. Zba, Zicbom, Svnapot)', () {
      expect(names, containsAll(['Zba', 'Zbb', 'Zbs', 'Zicbom', 'Svnapot']));
    });
  });
}
