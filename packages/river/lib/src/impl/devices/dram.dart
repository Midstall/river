import 'package:riscv/riscv.dart';

import '../../bus.dart';
import '../../clock.dart';
import '../../dev.dart';

/// A DRAM controller for River
class RiverDram extends Device {
  final int maxSize;
  final int channels;

  RiverDram({
    required String name,
    required int address,
    required this.maxSize,
    required this.channels,
    required ClockConfig clock,
  }) : super(
         name: name,
         compatible: 'river,dram',
         range: BusAddressRange(address, (8 + (23 * channels)) + maxSize),
         clock: clock,
         accessor: DeviceAccessor(
           '/$name',
           {
             0: DeviceField('ctrl', 1),
             1: DeviceField('status', 1),
             2: DeviceField('size', 4),
             3: DeviceField('training_ctrl', 1),
             4: DeviceField('training_status', 1),
             for (int i = 0; i < channels; i++) ...{
               (5 + (i * 9)): DeviceField('config$i', 2),
               (6 + (i * 9)): DeviceField('timing$i', 2),
               (7 + (i * 9)): DeviceField('train0_$i', 2),
               (8 + (i * 9)): DeviceField('train1_$i', 2),
               (9 + (i * 9)): DeviceField('vendor_$i', 2),
               (10 + (i * 9)): DeviceField('device_$i', 2),
               (11 + (i * 9)): DeviceField('type_$i', 1),
               (12 + (i * 9)): DeviceField('speed_$i', 2),
               (13 + (i * 9)): DeviceField('serial_$i', 8),
             },
           },
           type: DeviceAccessorType.mixed,
           memoryRange: BusAddressRange(
             8 + (23 * channels),
             (8 + (23 * channels)) + maxSize,
           ),
           ioRange: BusAddressRange(0, 8 + (23 * channels)),
         ),
       );

  static const ctrl = BitStruct({
    'enable': BitRange.single(0),
    'reset': BitRange.single(1),
    'warmup': BitRange.single(2),
    'refresh': BitRange.single(3),
    'scrub': BitRange.single(4),
    'ecc': BitRange.single(5),
  });

  static const status = BitStruct({
    'ready': BitRange.single(0),
    'training': BitRange.single(1),
    'error': BitRange.single(2),
    'reset': BitRange.single(3),
    'powered': BitRange.single(4),
    'ecc': BitRange.single(5),
  });

  static const trainingCtrl = BitStruct({
    'start': BitRange.single(0),
    'abort': BitRange.single(1),
  });

  static const trainingStatus = BitStruct({
    'busy': BitRange.single(0),
    'done': BitRange.single(1),
    'fail': BitRange.single(2),
  });

  static const train0 = BitStruct({
    'dq_delay': BitRange(0, 5),
    'dqs_delay': BitRange(6, 11),
    'rd_level': BitRange.single(12),
    'wr_level': BitRange.single(13),
    'valid': BitRange.single(15),
  });

  static const train1 = BitStruct({
    'vref': BitRange(0, 5),
    'odt': BitRange(6, 9),
    'drv': BitRange(10, 13),
    'valid': BitRange.single(15),
  });
}
