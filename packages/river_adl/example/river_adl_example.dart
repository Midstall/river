import 'dart:io';
import 'package:harbor/harbor.dart';
import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

class MyModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);

  DataField get c => output('c');

  MyModule(DataField a, DataField b) : super() {
    a = addInput('a', a);
    b = addInput('b', b);

    addOutput('c', type: a.type, source: DataLocation.register);

    c.bind(a + b);
  }
}

void main() async {
  final myModule = MyModule(
    DataField.from(1, name: 'a'),
    DataField.from(2, name: 'b'),
  );

  await myModule.build();

  final generatedAsm = myModule.generateAssembly();
  print(generatedAsm);

  final generatedBin = myModule.generateBinary();
  File('myProgram.bin').writeAsBytesSync(generatedBin);
}
