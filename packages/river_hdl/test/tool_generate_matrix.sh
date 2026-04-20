#!/usr/bin/env bash
# Regenerates the matrix cell files: test/<category>/<mxlen>_<uarch>_test.dart
# for every supported (category, mxlen, uarch). Each is a 5-line thin file that
# calls runMatrix with the table-driven config + instruction list. Run from the
# river_hdl/test directory. Gating mirrors microarchSupports in matrix_configs.dart:
#   - in-order runs all categories (branch included now that #69 is fixed).
#   - ooo / ooo_dual run all EXCEPT the in-order-only ones (loadstore/a/zacas,
#     whose OoO mem-FU path is incomplete - project_hdl_ooo_state).
# Adding a category: add it here AND to matrix_instructions.dart + matrix_configs.dart.
set -euo pipefail
cd "$(dirname "$0")"

cats=(base loadstore branch m a bitmanip zicond zacas csr fd d v)
declare -A uenum=( [inorder]=inOrder [ooo]=ooo [ooo_dual]=oooDual )

gen() {
  local cat=$1 mx=$2 ul=$3 uev=$4
  mkdir -p "$cat"
  cat > "$cat/${mx}_${ul}_test.dart" <<EOF
import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_instructions.dart';
import '../matrix_harness.dart';

void main() {
  const category = '$cat';
  const mxlen = RiscVMxlen.$mx;
  const uarch = Uarch.$uev;
  runMatrix(
    'matrix: \$category \${mxlenLabel(mxlen)} \${uarchLabel(uarch)}',
    matrixConfig(mxlen, uarch, category),
    instructionsFor(category, mxlen),
  );
}
EOF
}

count=0
for cat in "${cats[@]}"; do
  for mx in rv64 rv32; do
    for ul in inorder ooo ooo_dual; do
      # d (double) is rv64-only: a 64-bit double cannot ride the mxlen-width
      # result signal on rv32 - that needs the FloatingPoint64 operand-routing
      # fix (exec.dart ~586). v (vector) is rv64-only: the rv32 datapath hits a
      # 128-vs-64 swizzle mismatch. fd (single-precision F) now elaborates and
      # passes on rv32 after the #71 width-coercion fixes.
      if { [ "$cat" = "d" ] || [ "$cat" = "v" ]; } && [ "$mx" = "rv32" ]; then continue; fi
      # in-order-only categories have no OoO variant yet: loadstore/a/zacas (OoO
      # mem FU incomplete).
      if [ "$ul" != "inorder" ] && { [ "$cat" = "loadstore" ] || [ "$cat" = "a" ] || [ "$cat" = "zacas" ] || [ "$cat" = "fd" ] || [ "$cat" = "d" ] || [ "$cat" = "v" ]; }; then continue; fi
      gen "$cat" "$mx" "$ul" "${uenum[$ul]}"
      count=$((count + 1))
    done
  done
done
echo "generated $count cell files"
