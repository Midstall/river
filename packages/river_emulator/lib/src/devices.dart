import 'devices/clint.dart';
import 'devices/dram.dart';
import 'devices/flash.dart';
import 'devices/plic.dart';
import 'devices/sram.dart';
import 'devices/uart.dart';
import 'dev.dart';

export 'devices/clint.dart';
export 'devices/dram.dart';
export 'devices/flash.dart';
export 'devices/plic.dart';
export 'devices/sram.dart';
export 'devices/uart.dart';

const Map<String, DeviceFactory> kDeviceFactory = {
  'riscv,clint0': Clint.create,
  'river,dram': Dram.create,
  'riscv,plic0': Plic.create,
  'river,flash': Flash.create,
  'river,sram': Sram.create,
  'ns16550a': Uart.create,
};
