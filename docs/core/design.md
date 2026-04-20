# River Core Design

The River RISC-V core is a 32-bit or 64-bit core with multiple "design profiles" ranging from nano to macro.
This allows for a wide variety of applications and a modular design.

## Profiles

- RC1.n - River Core v1 *nano*
    - RV32IC
    - 32-bit River Core
    - Intended for small FPGA like the iCESugar
    - Intended to run RTOS
    - Scalar
- RC1.mi - River Core v1 *micro*
    - RV32IMAC + Zicsr
    - Supervisor & user modes
    - 32-bit River Core
    - Intended to run Linux
    - Scalar
- RC1.s - River Core v1 *small*
    - RV64IMAC + Zicsr
    - Supervisor & user modes
    - 64-bit River Core
    - Intended to run Linux
    - Scalar
- RC1.f - River Core v1 *full*
    - RV64GC + Zicsr
    - Supervisor & user modes
    - 64-bit River Core
    - Intended to run Linux
    - Scalar
- RC1.ma - River Core v1 *macro*
    - RV64GC + Zicsr
    - Supervisor & user modes
    - 64-bit River Core
    - Intended to run Linux
    - Superscalar

## Execution Modes

A River core is built in one of two execution modes, picked per profile by the
`ExecutionMode` config (`inOrder` or `outOfOrder`).

In `inOrder` mode (the nano, micro, small, and full profiles) the core runs the
microcode execution unit described below: one instruction is fetched, decoded,
and executed at a time. This is the compact configuration intended for small
FPGAs and tight area budgets.

In `outOfOrder` mode (the macro profile) the same front-end feeds an out-of-order
dual-issue backend with register renaming, an issue queue, multiple functional
units, and a reorder buffer for in-order commit. The two modes share the fetch
and decode logic and the microcode definitions, they differ in how execution and
retirement are scheduled.

## Components

River's core is split into 3 central components which matches the primary stages of the pipeline.

1. Fetch Unit - Fetches instructions
2. Decode Unit - Decodes instructions
3. Execution Unit - Executes instructions

These are the base modules every River core shares. The out-of-order backend adds
the rename, issue, functional-unit, and reorder-buffer blocks described later.

### Fetch Unit

River's fetch unit is very simple as to ensure the least amount of latency.
It simply reads a word length of memory or the L1 cache if present if RVC (RISC-V Compressed extension) is not enabled.

If the RVC extension is present, it reads the first half-word. Then it performs a mask check to ensure if it is a compressed instruction.
If the instruction is compressed, the fetch unit emits that into the IR (instruction register).
If the instruction is not compressed, the fetch unit will then read the other half-word of memory and combine the two.
The full instruction will then be loaded into IR.

A 32-bit instruction can straddle a word boundary when compressed code shifts
alignment, so the fetch path can issue a second read and join the high half-word
of one word with the low half-word of the next before presenting the full
instruction.

Two optional fetch engines trade area for instruction throughput. A pipelined
prefetch fetcher issues the next instruction read while the current instruction
is still being consumed downstream, holding results in a small instruction FIFO so
fetch latency overlaps decode and execution instead of serialising with them. It
keeps exactly one bus read outstanding at a time and drains any in-flight stale
response on a redirect, so a response is never mis-attributed to the wrong
address. The fetch port is interconnect-neutral: it only assumes a single read in
flight and one in-order response pulse per request, so the in-tree MMU/Wishbone
port works and an AXI or TileLink adapter presenting the same contract would too.

### Decode Unit

River has 2 decode unit types; static & dynamic. The static decode unit reads the microcode at build time.
It then generates decode circuitry based on the instructions enabled in the extension set.
This circuitry is designed to operate without a clock pulse as to minimize the latency.

The dynamic decode unit is backed by one of the two microcode ROMs.
It utilizes the microcode lookup ROM, this is reponsible for turning operation
decode patterns into the microcode operation index & operation count.

A combination of either the static, dynamic, or both decode units may be present on a River core.
It is up to whoever is running the HDL generator to decide on how the microcode should be utilized.

### Execution Unit

Just like River's decode unit has 2 types, so does the execution unit.
Both the static & dynamic execution units are design with similar concepts.

The static decode unit takes the extension set at build time and contains circuitry for any instruction
which is going to be statically included. It reads the static decode unit's operation index but does not contain
an operation count. Instead, each micro-op is duplicated for every possible instruction that is statically included.
This ensures the circuitry is as simple as possible and has the least amount of latency.

The dynamic decode unit will read the second microcode ROM which is known as the operation ROM.
This contains a lookup table of all micro-operations which an instruction will utilize.
Each address in the operation ROM is split in based on the bit length required to fit all instructions.
The second component of the address to the operation ROM is the bit length of the sum total of the instruction
which the most amount of micro-ops. This allows the dynamic decoder to have simple circuitry to jump between instructions.

On each clock cycle, a micro-op is executed. However, there are two additional cycles. Before the first micro-op of an instruction,
the execution unit performs an initialization of the internal registers. This will clear the ALU register & fence
flag, it then initializes the field registers with the fields from the decoded registers. After the last micro-op of an instruction,
the last cycle is executed which sets the done flag. This signals the execution unit has completed.

### Microcode

To facilitate the use of a unified codebase, River's entire design is built on microcode. This means there are two ROMs for the microcode
to operate correctly. One is known as the lookup ROM, the other is known as the operations ROM. Each are crucial to perform micro-ops
and decode operations.

#### Fields

Micro-op fields are the different registers which are utilized and are not internal.
There are 6 fields in total, 4 of them are derived from the decode unit.

- `rd` - Register destination
- `rs1` - Register source 1
- `rs2` - Register source 2
- `imm` - Immediate value
- `pc` - Program counter
- `sp` - Stack pointer

Each of these fields can be overriden but will modify a register inside of the execution unit
and not the backing register. The `ModifyLatchMicroOp` can be utilized to reset a source back
to the value it had at the beginning of the operation. However, that only applies if it is a
field backed by the decoder unit. This means the `pc` and `sp` fields cannot have their states
restored as they are not latched.

#### Sources

Sources are similar to micro-op fields but include the internal registers.
If a source appears with the same name as a field, it is an alias to that field and thus
will hold the same values & have the same latching behavior.

- `alu` - ALU result
- `imm` - Immediate
- `rs1` - Register source 1
- `rs2` - Register source 2
- `sp` - Stack pointer
- `rd` - Register desination
- `pc` - Program counter

### Out-of-Order Pipeline

In `outOfOrder` mode the in-order front-end (fetch, decode, rename) feeds an
issue queue that dispatches to out-of-order functional units, with a reorder
buffer restoring in-order commit. The functional units are two ALUs, one memory
unit, one branch unit, and one CSR unit.

Renaming uses a Register Alias Table that maps the 32 architectural registers to
a larger physical register file. It renames two instructions per cycle and keeps
a committed snapshot of the table so a flush can roll the speculative mapping
back. Each issue-queue entry carries its reorder-buffer tag, physical source and
destination indices, per-source ready bits and captured values, and the operand
and control metadata the target functional unit needs. An entry issues once both
its sources are ready.

The reorder buffer entry records the program counter, the new and previous
physical destinations, completion and exception state, the result, and any
control-flow redirect target. Commit happens in program order: it frees the
previous physical destination, applies branch and jump redirects, and handles
privileged returns by restoring the program counter and privilege mode from the
saved exception program counter and status.

Stores use a store queue so they do not stall commit waiting on memory. A store
pushes an entry when it executes (address and data known), and three pointers
split the queue into a committed-and-draining region and a speculative region. A
committed store drains to memory in program order in the background, so several
writes can be in flight at once. A load waits until the queue is empty so it sees
all older stores, and a flush drops only the speculative tail while committed
entries keep draining.

### Register File

The register file is a configurable multiport block. The backend is chosen for
the target: a banked or arbitered multiport built from simpler memories for
simulation and ASIC, or an ECP5 block-RAM (EBR) backend on FPGA. Its read latency
is accounted for by the pipeline rather than assumed to be zero. In out-of-order
mode the physical register file is larger than the 32 architectural registers to
back renaming. When floating point is enabled a second register file holds the FP
registers and is routed into the execution datapath alongside the integer file.

### Floating-Point and Vector

Floating point and vector execution live in the microcode execution unit. When a
micro-op reads or writes a floating-point register, a dedicated floating-point
register file is instantiated and wired into the execution datapath. The F and D
extensions cover arithmetic, the comparison operations, and conversions, plus a
multi-cycle iterative divide that runs one operation at a time under a small state
machine. The floating-point datapath is built on the ROHD-HCL floating-point
library.

The vector engine adds a vector register file of 32 registers each VLEN bits
wide, present when the ISA includes the V extension. The vector configuration
instructions write the element width and grouping into vtype and the active
element count into vl, and vector operations read them back. Integer element
operations are generic across the supported element widths and run over the full
vector length with proper handling of the active length and the tail, and LMUL
register grouping walks the registers of a destination group in turn.

### Memory and Address Translation

The MMU sits between the core and a downstream Wishbone master. It has two
upstream ports, one for instruction fetch and one data port for loads, stores,
and page-table walks, with a priority arbiter that favors the data port. When
translation is active it performs a hardware page-table walk supporting Sv39 and
Sv48 for both loads and stores and raises page faults on bad entries. With the
hypervisor extension it performs two-stage translation, where every guest-stage
pointer and the final leaf of the first-stage walk are themselves translated
through the guest-stage walk, and it reports guest faults separately.

### Privilege and Control Registers

The core tracks machine, supervisor, and user privilege in a mode register. With
the hypervisor extension a virtualization bit is also tracked and is saved and
restored through the status register on traps and privileged returns. Control and
status registers are described by a typed field configuration, and only declared
field bits are reconstructed on a read, so a readable register needs an explicit
field. A combinational frontdoor read port serves the pipeline and is borrowed by
the debugger while the hart is halted. Trap delivery computes the handler address
from the trap-vector register in either direct or vectored form, and delegation
routes selected traps and interrupts to supervisor mode. Alongside the standard
registers, River defines custom control registers including a pipeline and
speculation control register and the registers used to patch microcode at run
time.

### Debug Support

River cores may be built with external RISC-V Debug (spec 0.13.2) support. When
enabled, the core gains a halt finite state machine that freezes the pipeline at
an instruction boundary when the debugger asserts a halt request. On halt the
program counter is latched into `dpc`, and on resume the counter is restored from
`dpc` so the debugger can redirect execution by writing it. The `dcsr` control
register (CSR 0x7b0) holds the debug version, the halt cause, the privilege at
halt, and the `ebreak` enable bits. With those bits set an executed `ebreak`
re-enters debug mode instead of taking a breakpoint trap.

While the pipeline is frozen its register file ports and combinational CSR read
port are idle, so the debugger borrows them. An abstract access-register command
reads or writes any GPR and reads any architectural CSR through these idle ports
without a dedicated debug datapath. The non-debug-maskable reset bit from the
debug module is OR-ed into the hart reset at the SoC level, so a debugger reset
drops the hart while leaving the debug logic itself alive.

### Debug Transport

The TAP, the Debug Transport Module, and the Debug Module are fused into one
system-clock-domain module. It samples the JTAG clock with rising-edge detection,
so a single bit-bang pulse advances the TAP by one step and there is no JTAG to
core clock-domain crossing to reason about. The DMI register is 41 bits. The
Debug Module also exposes a System Bus Access port, a small bus master that reads
and writes memory independently of the hart, so memory inspection works whether
the hart is halted or running. A System Bus to Wishbone adapter presents that
port as a second fabric master.

On an ECP5 the debugger reaches the Debug Module over the FPGA's own
configuration JTAG (the same port a flashing tool such as dirtyJtag drives)
through the `JTAGG` ER1 user register and a SiFive nested-tap BSCAN tunnel. This
needs no extra package pins. The tunnel module reconstructs the inner TAP's
`tck`, `tms`, and `tdi` from a framed scan of the ER1 data register and returns
its `tdo`, so the full Debug Module is reachable from a stock RISC-V OpenOCD with
`riscv use_bscan_tunnel`.
