import 'package:rohd/rohd.dart';
import '../data_port.dart';

/// A sized prefix data port writer to multiple output data ports.
///
/// Using multiple data ports for writing, this is capable of updating a memory
/// model without reading first. This however does increase the circuit complexity
/// due to having more duplicate lines. This is suitable when the memory model supports
/// multiple data ports of different sizes.
class SizedWriteMultiDataPort extends Module {
  SizedWriteMultiDataPort(
    Logic clk,
    Logic reset, {
    required DataPortInterface backingWriteByte,
    required DataPortInterface backingWriteHalf,
    required DataPortInterface backingWriteWord,
    DataPortInterface? backingWriteDword,
    required DataPortInterface source,
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    backingWriteByte = backingWriteByte.clone()
      ..connectIO(
        this,
        backingWriteByte,
        outputTags: {DataPortGroup.control, DataPortGroup.data},
        inputTags: {DataPortGroup.integrity},
        uniquify: (og) => 'backingWriteByte_$og',
      );

    backingWriteHalf = backingWriteHalf.clone()
      ..connectIO(
        this,
        backingWriteHalf,
        outputTags: {DataPortGroup.control, DataPortGroup.data},
        inputTags: {DataPortGroup.integrity},
        uniquify: (og) => 'backingWriteHalf_$og',
      );

    backingWriteWord = backingWriteWord.clone()
      ..connectIO(
        this,
        backingWriteWord,
        outputTags: {DataPortGroup.control, DataPortGroup.data},
        inputTags: {DataPortGroup.integrity},
        uniquify: (og) => 'backingWriteWord_$og',
      );

    if (backingWriteDword != null) {
      backingWriteDword = backingWriteDword.clone()
        ..connectIO(
          this,
          backingWriteDword,
          outputTags: {DataPortGroup.control, DataPortGroup.data},
          inputTags: {DataPortGroup.integrity},
          uniquify: (og) => 'backingWriteDword_$og',
        );
    }

    source = source.clone()
      ..connectIO(
        this,
        source,
        outputTags: {DataPortGroup.integrity},
        inputTags: {DataPortGroup.control, DataPortGroup.data},
        uniquify: (og) => 'source_$og',
      );

    Sequential(clk, [
      If(
        reset,
        then: [
          source.done < 0,
          source.valid < 0,
          backingWriteByte.en < 0,
          backingWriteByte.addr < 0,
          backingWriteHalf.en < 0,
          backingWriteHalf.addr < 0,
          backingWriteWord.en < 0,
          backingWriteWord.addr < 0,

          if (backingWriteDword != null) ...[
            backingWriteDword.en < 0,
            backingWriteDword.addr < 0,
          ],
        ],
        orElse: [
          If(
            source.en,
            then: [
              Case(
                source.data.slice(6, 0),
                [
                  CaseItem(Const(8, width: 7), [
                    backingWriteByte.en < 1,
                    backingWriteByte.addr < source.addr,
                    backingWriteByte.data < source.data.slice(14, 7),
                    source.done < backingWriteByte.done,
                    source.valid < backingWriteByte.valid,
                  ]),
                  CaseItem(Const(16, width: 7), [
                    backingWriteHalf.en < 1,
                    backingWriteHalf.addr < source.addr,
                    backingWriteHalf.data < source.data.slice(22, 7),
                    source.done < backingWriteHalf.done,
                    source.valid < backingWriteHalf.valid,
                  ]),
                  CaseItem(Const(32, width: 7), [
                    backingWriteWord.en < 1,
                    backingWriteWord.addr < source.addr,
                    backingWriteWord.data < source.data.slice(38, 7),
                    source.done < backingWriteWord.done,
                    source.valid < backingWriteWord.valid,
                  ]),
                  if (backingWriteDword != null)
                    CaseItem(Const(64, width: 7), [
                      backingWriteDword.en < 1,
                      backingWriteDword.addr < source.addr,
                      backingWriteDword.data < source.data.slice(70, 7),
                      source.done < backingWriteDword.done,
                      source.valid < backingWriteDword.valid,
                    ]),
                ],
                defaultItem: [
                  source.done < 0,
                  source.valid < 0,
                  backingWriteByte.en < 0,
                  backingWriteByte.addr < 0,
                  backingWriteHalf.en < 0,
                  backingWriteHalf.addr < 0,
                  backingWriteWord.en < 0,
                  backingWriteWord.addr < 0,

                  if (backingWriteDword != null) ...[
                    backingWriteDword.en < 0,
                    backingWriteDword.addr < 0,
                  ],
                ],
              ),
            ],
            orElse: [
              source.done < 0,
              source.valid < 0,
              backingWriteByte.en < 0,
              backingWriteByte.addr < 0,
              backingWriteHalf.en < 0,
              backingWriteHalf.addr < 0,
              backingWriteWord.en < 0,
              backingWriteWord.addr < 0,

              if (backingWriteDword != null) ...[
                backingWriteDword.en < 0,
                backingWriteDword.addr < 0,
              ],
            ],
          ),
        ],
      ),
    ]);
  }
}

/// A sized prefix data port writer to a single data port.
///
/// Using a single data port for reading & writing, this is capable of updating
/// a memory model using the least amount of data ports. However, it performs a read
/// before a write. This is suitable when the memory model does not suport multiple
/// data ports of different sizes.
class SizedWriteSingleDataPort extends Module {
  SizedWriteSingleDataPort(
    Logic clk,
    Logic reset, {
    required DataPortInterface backingRead,
    required DataPortInterface backingWrite,
    required DataPortInterface source,
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    if (backingRead.addr.width != backingWrite.addr.width) {
      throw 'Backing read & backing write must have the same address width';
    }

    if (backingRead.data.width != backingWrite.data.width) {
      throw 'Backing read & backing write must have the same data width';
    }

    if (source.data.width < 7) {
      throw 'Source port must be at least 7 bits to fit the width prefix';
    }

    if (backingRead.addr.width != source.addr.width) {
      throw 'Backing data ports and source port must have the same address width';
    }

    if (backingRead.data.width != (source.data.width - 7)) {
      throw 'Backing data ports and source port must have the same data width';
    }

    backingWrite = backingWrite.clone()
      ..connectIO(
        this,
        backingWrite,
        outputTags: {DataPortGroup.control, DataPortGroup.data},
        inputTags: {DataPortGroup.integrity},
        uniquify: (og) => 'backingWrite_$og',
      );

    backingRead = backingRead.clone()
      ..connectIO(
        this,
        backingRead,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'backingRead_$og',
      );

    source = source.clone()
      ..connectIO(
        this,
        source,
        outputTags: {DataPortGroup.integrity},
        inputTags: {DataPortGroup.control, DataPortGroup.data},
        uniquify: (og) => 'source_$og',
      );

    final width = source.data.width - 7;
    final value = source.data.slice(source.data.width - 1, 7);

    final dataSize = source.data.slice(6, 0).zeroExtend(width);

    final writeMask = Logic(name: 'writeMask', width: width);
    writeMask <=
        ((Const(1, width: width) << dataSize) - Const(1, width: width));

    Sequential(clk, [
      If(
        reset,
        then: [
          source.done < 0,
          source.valid < 0,
          backingRead.en < 0,
          backingRead.addr < 0,
          backingWrite.en < 0,
          backingWrite.addr < 0,
          backingWrite.data < 0,
        ],
        orElse: [
          If(
            source.en,
            then: [
              backingRead.en < 1,
              backingRead.addr < source.addr,
              backingWrite.en < backingRead.done & backingRead.valid,
              backingWrite.addr < source.addr,
              backingWrite.data <
                  ((backingRead.data & ~writeMask) | (value & writeMask)),
              source.done < backingRead.done & backingWrite.done,
              source.valid < backingRead.valid & backingWrite.valid,
            ],
            orElse: [
              source.done < 0,
              source.valid < 0,
              backingRead.en < 0,
              backingRead.addr < 0,
              backingWrite.en < 0,
              backingWrite.addr < 0,
              backingWrite.data < 0,
            ],
          ),
        ],
      ),
    ]);
  }
}
