import 'dart:io';

/// Send a raw binary to the River serial boot monitor.
///
/// Usage: `dart run river_maskrom:river_load <payload.bin> [device]`
/// (device defaults to /dev/ttyACM0).
///
/// Keep a terminal (e.g. `picocom -b 115200`) attached in another window to
/// see the monitor's K/E verdict and the program's output. picocom holds the
/// port settings, this tool only writes the frame. With no terminal attached,
/// configure the port first: `stty -F /dev/ttyACM0 115200 raw`.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: river_load <payload.bin> [device]');
    exit(64);
  }
  final bin = await File(args[0]).readAsBytes();
  final dev = args.length > 1 ? args[1] : '/dev/ttyACM0';
  if (bin.length > 0xffff) {
    stderr.writeln('payload too large: ${bin.length} bytes (max 65535)');
    exit(65);
  }

  final sum = bin.fold<int>(0, (a, b) => (a + b) & 0xff);
  final frame = [bin.length & 0xff, (bin.length >> 8) & 0xff, ...bin, sum];

  // Plain write-only: append mode seeks to end-of-file on open, which a tty
  // (a character device) rejects with an illegal-seek error.
  final port = File(dev).openSync(mode: FileMode.writeOnly);
  // writeFromSync is a direct write syscall, and a tty rejects fsync with
  // EINVAL, so there is deliberately no flush here.
  port.writeFromSync(frame);
  port.closeSync();

  stdout.writeln(
    'sent ${bin.length}-byte payload (+3 framing) to $dev, '
    'checksum 0x${sum.toRadixString(16).padLeft(2, '0')}',
  );
}
