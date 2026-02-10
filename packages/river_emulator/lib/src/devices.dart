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

const Map<String, DeviceEmulatorFactory> kDeviceEmulatorFactory = {
  'riscv,clint': RiscVClintEmulator.create,
  'river,dram': DramEmulator.create,
  'riscv,plic': RiscVPlicEmulator.create,
  'river,flash': FlashEmulator.create,
  'river,sram': SramEmulator.create,
  'river,uart': UartEmulator.create,
};
