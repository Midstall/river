import 'package:river/river.dart';
import 'package:test/test.dart';

// Guards River's registered RISC-V architecture ID (marchid), per
// https://github.com/riscv/riscv-isa-manual/blob/main/marchid.md
// riverArchId is the default RiverCoreConfig.archId, so a change here would
// silently change every core's marchid.
void main() {
  test(
    'River marchid (riverArchId) is the registry value 49',
    () => expect(riverArchId, 49),
  );
}
