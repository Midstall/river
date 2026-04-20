import 'package:rohd/rohd.dart';

/// Target-agnostic, BRAM-inferable initialised ROM/RAM.
///
/// Emits behavioural SystemVerilog (a packed [mem] array with an `initial` block
/// and a registered read) that yosys `synth_xilinx` maps to a RAMB (and
/// `synth_ecp5` to a DP16KD). Xilinx counterpart of [Ecp5InitRom]: on Xilinx the
/// flop-based `RegisterFile(resetValue:)` fallback explodes to ~94k FF for the
/// exec microcode ROM. Read latency 1 (registered) and optional single write
/// port, so callers wire it exactly like [Ecp5InitRom].
class InferredInitRom extends Module with SystemVerilog {
  /// Registered read data, one cycle behind [rdAddr].
  Logic get rdData => output('rd_data');

  final List<BigInt> _contents;
  final int _width;
  final int _addrW;
  final bool _hasWrite;

  InferredInitRom(
    Logic clk, {
    required List<BigInt> contents,
    required int width,
    required Logic rdAddr,
    Logic? wrEn,
    Logic? wrAddr,
    Logic? wrData,
    super.name = 'inferred_init_rom',
    // Distinct stable module name per ROM (two instances with different
    // contents/width are different modules), matching Ecp5InitRom.
    super.definitionName,
    super.reserveDefinitionName = true,
  }) : _contents = contents,
       _width = width,
       _addrW = rdAddr.width,
       _hasWrite = wrEn != null {
    addInput('clk', clk);
    addInput('rd_addr', rdAddr, width: rdAddr.width);
    if (wrEn != null) {
      addInput('wr_en', wrEn);
      addInput('wr_addr', wrAddr!, width: wrAddr.width);
      addInput('wr_data', wrData!, width: width);
    }
    addOutput('rd_data', width: width);
  }

  @override
  String? definitionVerilog(String definitionType) {
    final depth = 1 << _addrW;
    final aHi = _addrW - 1;
    final wHi = _width - 1;
    final b = StringBuffer()
      ..writeln('module $definitionType (')
      ..writeln('  input logic clk,')
      ..writeln('  input logic [$aHi:0] rd_addr,');
    if (_hasWrite) {
      b
        ..writeln('  input logic wr_en,')
        ..writeln('  input logic [$aHi:0] wr_addr,')
        ..writeln('  input logic [$wHi:0] wr_data,');
    }
    b
      ..writeln('  output logic [$wHi:0] rd_data')
      ..writeln(');')
      // ram_style hint steers yosys/vivado to block RAM.
      ..writeln(
        '  (* ram_style = "block" *) logic [$wHi:0] mem [0:${depth - 1}];',
      )
      ..writeln('  initial begin')
      ..writeln(
        '    for (int unsigned i = 0; i < $depth; i++) mem[i] = ${_width}\'d0;',
      );
    for (var i = 0; i < _contents.length && i < depth; i++) {
      final hex = _contents[i].toRadixString(16);
      b.writeln("    mem[$i] = ${_width}'h$hex;");
    }
    b
      ..writeln('  end')
      ..writeln('  logic [$wHi:0] rd_q;')
      ..writeln('  always_ff @(posedge clk) begin');
    if (_hasWrite) {
      b.writeln('    if (wr_en) mem[wr_addr] <= wr_data;');
    }
    b
      ..writeln('    rd_q <= mem[rd_addr];')
      ..writeln('  end')
      ..writeln('  assign rd_data = rd_q;')
      ..writeln('endmodule');
    return b.toString();
  }
}
