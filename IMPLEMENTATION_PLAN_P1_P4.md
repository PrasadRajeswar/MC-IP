# MC implementation review through Phase 4

Reviewed: 3 November 2026.

Source: `/home/sai-preetham/Documents/Specifications/MC_IP_Microarchitecture_Spec6.pdf`.
The PDF identifies itself as revision 0.4, draft for review. Phase definitions are
in Section 11 (PDF page 21); verification gates are in Section 12.3 (page 23);
the final module hierarchy is in Section 13.1 (page 24).

This is an implementation inventory and proposed work breakdown. Proposed files
below have not been created, and existing RTL has not been changed by this review.
An existing filename or a simulation reaching `$finish` does not establish that
its phase has met the specification's exit criteria.

## Current structure and status

Keep `src_mc/rtl` and `src_mc/tb` as the active source locations. `Phase_1/` is the
original source snapshot; avoid compiling it together with `src_mc/rtl`, because
the module names overlap and the arbiters differ. The AXI-FDI bridge under `src/`
is a separate design and should have a separate source list.

There are currently 15 RTL files and four testbench files in `src_mc`.

| Phase | Existing RTL | Assessment | Work required to reach the phase gate |
| --- | --- | --- | --- |
| P1: single-PC core | `mc_pc_core`, `mc_cmdq`, `mc_wdb`, `mc_rdb`, `mc_bank_state`, `mc_timing_check`, `mc_refresh_engine`, shared `mc_arbiter` | Scheduler and storage are present; the input is already decoded and the payload is one 32-bit lane word. Core test is a smoke test. | Define the command/data contract, repair testbench wiring, and verify legal command sequencing, ordering assumptions, buffers, refresh and backpressure against a checked model. |
| P2: DFI formatter | `mc_dfi_fmt` | Registered 22-bit row / 12-bit column packing and 64-bit lane routing exist. Basic directed checks pass. | Add DFI command/data timing, payload scheduling, protocol assertions and the agreed initialization/control boundary. |
| P3: AXI front end and APB CSR | `mc_axi_sub`, `mc_addr_decode`, `mc_axi_cdc`, `mc_async_fifo` | AXI submodule is wiring only; fixed decode and five AXI CDC FIFOs exist. No APB/CSR subsystem or transaction-to-PC backend exists. | Implement bursts, routing, width conversion, responses, ID ordering, errors, CSR/register generation and APB CDC. Verify AXI traffic through a real PC core. |
| P4: one channel, two PCs | `mc_ch_arb`, `mc_channel_integration`, shared `mc_arbiter` | Independent row/column arbitration feeds a formatter. The integration module does not instantiate either PC core. | Instantiate two real PC cores, connect grant feedback, independent buffers and data lanes, and verify end-to-end channel behavior under contention. |

No P1-P4 exit gate is established by the current test suite. Full replication to
16 channels / 32 PCs belongs to P5; automated low-power entry/exit belongs to P6.

## Proposed file structure

The specification names the core modules, `mc_dfi_if`, `mc_csr`, `mc_apb_if`,
`mc_sync_dfi`, `mc_perf_mon` and final `mc16x2` top. Helper names below, such as
`mc_axi_burst`, are suggested implementation boundaries rather than names
required by the specification. They can be merged when that makes the design
simpler. Keep the current flat RTL structure; adding phase directories would
duplicate modules shared by several phases.

```text
src_mc/
  IMPLEMENTATION_PLAN_P1_P4.md  this review
  rtl/
    mc_pc_core.sv             existing: single-PC integration and scheduler
    mc_cmdq.sv                existing: command slots and allocation
    mc_wdb.sv                 existing: per-PC write storage
    mc_rdb.sv                 existing: per-PC read storage and issue IDs
    mc_bank_state.sv          existing: per-PC open-bank/open-row state
    mc_timing_check.sv        existing: DRAM timing counters
    mc_refresh_engine.sv      existing: per-PC periodic refresh requests
    mc_arbiter.sv             existing: reused at PC and channel levels
    mc_dfi_fmt.sv             existing: per-channel command/data formatting
    mc_axi_sub.sv             existing: front-end shell; behavior to implement
    mc_addr_decode.sv         existing: fixed address-field extraction
    mc_axi_cdc.sv             existing: five AXI CDC FIFOs and AW/AR decode
    mc_async_fifo.sv          existing: Gray-pointer FIFO primitive
    mc_ch_arb.sv              existing: shared row/column arbitration
    mc_channel_integration.sv existing: arbiter/formatter subassembly
    mc_axi_burst.sv           proposed: burst expansion and validation
    mc_axi_to_pc.sv           proposed: transaction routing and queue admission
    mc_axi_completion.sv      proposed: read assembly, B/R responses, ID ordering
    mc_pc_data_path.sv        proposed: per-PC lane sequencing / width conversion
    mc_apb_if.sv              missing: APB4 interface
    mc_csr.sv                 missing: generated registers and CSR integration
    mc_sync_dfi.sv            missing: coherent APB/core configuration/status CDC
    mc_dfi_if.sv              missing: init/update/control; low power extended in P6
    mc_perf_mon.sv            missing: required status/performance counters
    mc_channel.sv             proposed: two PC cores + arbiter/formatter + data paths
    mc_p4_top.sv              proposed: single-channel AXI/APB integration harness
  csr/
    mc_regs.rdl               missing input: approved register description
  tb/
    tb_mc_core.sv             existing: repair and add checked P1 scenarios
    tb_mc_dfi_fmt.sv          existing: formatter module is named tb_dfi_formatter
    tb_mc_async_fifo.sv       existing: basic FIFO tests
    tb_mc_channel_integration.sv existing: arbiter/formatter stimulus only
    tb_mc_axi_cdc.sv          proposed: all five FIFOs with asynchronous clocks
    tb_mc_axi_frontend.sv     proposed: AXI through decode/CDC to one PC core
    tb_mc_csr.sv              proposed: APB registers, errors and CDC
    tb_mc_channel.sv          proposed: two real PC cores sharing one DFI instance
    tb_mc_p4_top.sv           proposed: AXI/APB to one channel end-to-end
    models/
      mc_dfi_hbm_model.sv     proposed: data store, return timing and timing checks
    assertions/
      mc_axi_sva.sv           proposed: AXI handshake and burst checks
      mc_dfi_sva.sv           proposed: command timing, PC selection, lane isolation
      mc_arbiter_sva.sv       proposed: legal one-hot issue and bounded progress
  sim/
    Makefile                 proposed: reproducible build/run/lint entry points
    p1.f / p2.f / p3.f / p4.f proposed: explicit source order and test tops
```

Use `mc_p4_top` only as a one-channel milestone harness. The final `mc16x2` top
and 16-channel replication are P5 work. A shared package is optional: if added,
keep one owner for command layouts, timing constants and encodings, and compile
it first. Do not add duplicate definitions in each phase directory.

## P1: finish and verify the single-PC contract

1. **Repair `tb_mc_core`.** It currently grants every candidate immediately and
   fabricates a read return. It does not instantiate the formatter. Its
   `wdb_raddr` and DFI output signals are undriven, and WDB release depends on an
   undriven DFI enable. Either connect a formatter/data path or remove those
   unused DFI signals from the core-only test and model payload consumption
   explicitly. Check transmitted data, masks, read ID/data, and all error flags.
2. **Document the queue entry and data contract.** The default core command is
   36 bits: ID 8, write flag 1, row 14, BG 2, BA 2, column 5, WDB pointer 4.
   It has no AXI burst count, beat position, response code, or AXI attributes.
   Decide which metadata belongs in the frontend/completion tracker and what
   identity the core carries. The CMDQ cannot by itself establish AXI ordering.
3. **Check actual-issue updates.** Bank state, timing counters, CMDQ removal and
   read-ID allocation must update only on the corresponding accepted channel
   grant. Exercise denied grants for multiple cycles and refresh preemption.
4. **Verify timing boundaries.** Exercise each of tRCD, tRAS, tRP, tRC, tRRD,
   tFAW, tCCD, tWTR, tWR, tRTP and tRFC immediately before and at its legal
   boundary. Exercise refresh with multiple open banks and pending traffic.
   Current timing defaults match Section 7.3.2's table; this is not vendor signoff.
5. **Fix write recovery accounting when adding the data path.** Current
   `mc_timing_check` starts `cnt_wr` on `issued_wr`; Section 7.3.2 defines tWR
   relative to the last write data. Delayed/multiword payloads require last-data
   timing or an equivalent correctly derived delay before PRE/REF is allowed.
6. **Exercise storage limits and ordering.** Check CMDQ/WDB/RDB full conditions,
   concurrent enqueue/dequeue, pointer wrap, RDB stalls and no early WDB reuse.
   Same-ID transactions need an ordering constraint or completion mechanism
   when connected to AXI; the RDB currently restores IDs in DRAM issue order.

Exit: directed and basic random tests against a checked behavioral model, with
no timing violations, lost payloads, incorrect completions or buffer overflows.

## P2: complete the DFI boundary

- Retain the existing field mapping: row `[21]` PC, `[20:18]` command,
  `[17:16]` BG, `[15:14]` BA, `[13:0]` row; column `[11]` PC, `[10:9]`
  command, `[8:7]` BG, `[6:5]` BA, `[4:0]` column.
- Verify PC0 occupies data `[31:0]` and PC1 `[63:32]`, with corresponding
  mask nibbles and enable bits. Preserve each lane independently.
- Add a per-PC data sequencer with configured PHY write/read timing. The
  formatter currently registers supplied data/enables; it does not derive
  command-to-data offsets or track a granted WDB pointer. Hold each pointer
  until its last payload word has been captured, then free the entry.
- Account for the formatter's register stage and read-return register stage
  consistently in the model, latency settings and completion bookkeeping.
- Define the init/update/control connection: reset/CS/CKE, init-complete gating,
  update handshakes and error reporting. Implement the startup subset needed
  for P1-P4 testing; complete automated power-down/self-refresh in P6.
- Add assertions for legal encodings, valid-qualified commands, PC routing,
  payload timing, reset behavior and no traffic before initialization.

Exit: formatter assertions and checked read/write data timing pass for both
PC selections, including simultaneous activity on independent data lanes.

## P3: implement the frontend, responses and APB CSR

### AXI and the transaction backend

- `mc_axi_sub` currently forwards wires without transaction state. Implement
  frontend behavior there and/or in helpers, with one clear owner for burst
  state, admission and completions. Keep controller-side transaction state in
  `dfi_clk` after the existing CDC FIFOs where practical.
- Validate INCR-only bursts, length 1-16 beats, supported sizes/alignment,
  reserved address bits and the supported memory range. Define error handling
  for unsupported requests and malformed/early/late WLAST, including consuming
  the required traffic so an error cannot deadlock the port.
- Associate AW with W in acceptance order, generate each beat address from
  size/length, and decode each generated address. A single decode of the burst
  header is insufficient when later beat addresses cross column/bank/PC fields.
- Route commands and payload to the selected PC with end-to-end backpressure.
  Reserve CMDQ/WDB/completion resources before accepting work that depends on
  them; handle AR and AW competition for a shared command input.
- Resolve the 256-bit AXI to 32-bit PC-lane mismatch. A full AXI beat contains
  eight 32-bit words at this logical interface. Specify their ordering, mask
  conversion, storage ownership, return assembly and DRAM-command granularity.
  Do not assume eight DRAM commands per beat without an approved burst contract.
  Current WDB/RDB entries each carry only one 32-bit word; their entry counts
  cannot be interpreted as full 256-bit beats without a storage change.
- Generate one posted B response per write burst once all write payload has
  been accepted and its commands are owned as required by Section 5.1. Preserve
  BID, report admission/protocol errors, and report later PHY faults via IRQ.
- Assemble 256-bit R beats, RID, RRESP and RLAST. Preserve per-ID request order,
  including requests to different PCs, and hold response payload stable under
  RREADY/BREADY stalls. The current RDB alone does not provide this behavior.
- Carry the required attributes. `mc_axi_cdc` includes ARCACHE/ARPROT, but
  `mc_axi_sub` currently has no corresponding read-side ports. Resolve the
  specified AWLOCK handling at the AXI boundary. QoS remains unused by arbitration.
- Implement WDATA timeout and transaction-limit bookkeeping after resolving
  the outstanding-count ambiguity described below.

### CDC

The existing FIFO widths/depths match Section 6.2.2:

| Channel | Direction | Width | Depth |
| --- | --- | --- | --- |
| AW | AXI to DFI | 72 | 8 |
| W | AXI to DFI | 289 | 16 |
| AR | AXI to DFI | 72 | 8 |
| B | DFI to AXI | 10 | 8 |
| R | DFI to AXI | 267 | 16 |

Add tests for all five channels with independent clock phase, sustained stalls,
FIFO wrap and reset sequencing. Add synchronizer annotations/CDC module tags,
occupancy visibility and appropriate CDC constraints. The current FIFO uses a
combinational memory read; verify or adapt the implementation to meet the
specified RAM-based W/R FIFO requirement with the intended memory technology.
Simulation cannot establish structural CDC/RDC signoff.

### APB and registers

- Add `mc_apb_if`, generated `mc_csr`, `mc_sync_dfi` and the counters/status
  needed by the approved register map. Implement SETUP/ACCESS sequencing,
  PSTRB, waits, read data, invalid-access PSLVERR and timeout handling.
- Obtain the companion register reference and RDL/IP-XACT source. The supplied
  PDF gives high-level ranges but not exact register offsets, fields, reset
  values or access semantics. Do not invent those as a compliant register map.
- Transfer multi-bit configuration coherently. A two-flop synchronizer per
  bit does not by itself guarantee an atomic configuration word. Use stable
  held data with a synchronized request/acknowledgement event or another
  reviewed coherent bridge. Handle status snapshots and sticky error events.
- Connect global/channel enables, DFI latency settings, WDATA/APB timeouts,
  queue/FIFO occupancy, performance events, error masks/status and IRQ.

Exit: checked AXI transactions reach one real PC through CDC/decode; burst data,
IDs, masks and responses are correct; APB accesses and CSR CDC pass their tests;
frontend protocol checks and structural CDC review satisfy the P3 gate.

## P4: integrate one complete channel

Add `mc_channel` around two instances of `mc_pc_core` and the existing
`mc_channel_integration` arbiter/formatter subassembly. Each core keeps its own
CMDQ/WDB/RDB, bank table, timing checker, refresh state and data sequencer.

Connect each core's row/column candidate fields to the matching arbiter input;
drive legality from the core's valid legal candidates. Route `row_issue[pc]`
and `col_issue[pc]` back only to that core. Connect `row_req_is_ref` to the row
refresh-priority input. Normal column requests do not need refresh priority.
Keep `mc_arbiter` shared: the core ties its priority input low because its
refresh bypass is handled in dispatch; the channel uses explicit refresh
priority as required by Sections 5.5-5.6.

The per-PC data paths must consume the accepted column command and its WDB
pointer/ID, schedule write data and read enables at the agreed offsets, route
return-valid independently and release buffers only at the defined transfer
point. The current arbiter/formatter wrapper accepts externally supplied data;
it does not implement those connections.

Add a single-channel `mc_p4_top` that joins the AXI/APB subsystem and
`mc_channel`. Define how a P4 harness handles addresses selecting channels not
instantiated: constrain valid test traffic and give unsupported selections a
documented error response. Keep the final fixed 16-channel address decode.

P4 tests must use two actual cores and cover:

- Simultaneous row requests and simultaneous column requests from PC0/PC1.
- A row command from one PC and a column command from the other in one cycle.
- Sustained non-refresh contention, counter ties/saturation and bounded progress
  under explicit assumptions about timing legality and downstream acceptance.
- Refresh priority, simultaneous refresh demand, refresh preparation and tRFC.
- Overlapping PC data transfers following serialized command issue, correct
  PC-select fields, and no cross-PC data, mask, ID or buffer-pointer mixing.
- AXI response stalls, per-PC full buffers and same-ID ordering across PCs.
- Initialization/reset gating and error/IRQ observation through the P3 CSR path.

Exit: checked end-to-end traffic through one channel / two PCs meets the P4
gate. A generated-candidate arbiter test remains useful as a unit test but
cannot establish this integration result.

## Specification decisions needed before claiming compliance

| Topic | Conflicting or incomplete source | Implementation consequence |
| --- | --- | --- |
| Address mapping | Section 3.1.4 fixes bit slices and explicitly forbids remapping; Section 4.3 describes programmable interleave. | Use Section 3.1.4 for this revision's plan; confirm removal/deferral of the older programmable text. |
| Outstanding requests | Section 3.1.2 says 64; Section 5.4 derives 1024 controller-wide; Section 13.2 lists completion tracking depth 256 per PC. | Agree on separate port, per-PC and completion-storage limits and what counts as one outstanding transaction. |
| CSR addresses | Sixteen 4-KiB channel windows starting at 0x1000 reach 0x10FFF, overlapping performance/IRQ ranges at 0xF000/0xF400. | Obtain a corrected register map before generating address decode. |
| Reset sequencing | Section 6.2.3 forbids core reset release while AXI reset is asserted; Section 8's startup sequence releases the core before AXI. | Resolve release order and domain-local reset handling before adding startup assertions. |
| Burst and DFI encoding | AXI is 256 bits, PC storage/lane words are 32 bits; exact memory burst mapping is absent. The 2-bit column field is described with more than four command names. | Approve the data/command contract and supported encodings before burst/auto-precharge implementation. |
| Fixed clocks/timings | Section 6 fixes 500 MHz / 1 GHz / 50 MHz; some later text mentions clock ratios or other APB bounds. DRAM timings are fixed in Section 7.3.2, while reset/register prose refers to programming timing CSRs. | Use the fixed clock plan; distinguish fixed DRAM timing constants from PHY latency settings and clarify what is writable. |

The selected memory/PHY definitions and companion RDL are external inputs still
needed for signoff. Their absence does not prevent core/unit-test repairs or
the architectural integration work above.

## Validation performed for this review

All four existing testbenches built and ran with Verilator using
`--binary --timing --assert -Wno-fatal`. Build products/logs were placed under
`/tmp/mc_phase4_review`, outside the source tree. These are simulation checks,
not synthesis, timing closure, formal proof or CDC signoff.

| Testbench | Result | Evidence and limit |
| --- | --- | --- |
| `tb_mc_core` | Reached completion | Printed ACT/WR/RD, ID 0x22 read completion, refresh PRE/REF, and zero printed error flags. No self-checking end-to-end data scoreboard; formatter/WDB test wiring is incomplete. |
| `tb_dfi_formatter` from `tb_mc_dfi_fmt.sv` | Directed checks passed | Checks reset, field packing, lane routing and strobes. Does not establish configurable PHY timing or full DFI protocol compliance. |
| `tb_mc_async_fifo` | Basic tests passed | Checks reset, FIFO fill/drain and data. Does not exercise the whole five-channel AXI CDC subsystem. |
| `tb_mc_channel_integration` | Reached completion | Drives synthetic candidates and prints grants; contains no assertions/fatal checks and no PC core instances. |

An additional `--lint-only --timing --Wall -Wno-fatal` run on the core test
reported 12 undriven testbench signals, unused signals and mixed synchronous/
asynchronous reset use. The earlier default lint success did not establish a
warning-free testbench. Repair these before treating smoke output as a gate.

## Recommended execution order

1. Repair the P1 testbench and add checked core/timing/buffer/refresh scenarios.
2. Settle the burst/lane/ID contract and complete P2 data scheduling/assertions.
3. Implement P3 AXI routing/completions and verify the five CDC FIFOs end-to-end;
   implement APB/CSR in parallel once the register source/map is available.
4. Build `mc_channel` with two real cores, then the AXI/APB P4 harness, and add
   saturation, refresh and lane-isolation regression checks.
5. Add phase source lists, a simulation Makefile, structural CDC/RDC checks and
   an early synthesis timing estimate for the 1-GHz scheduler/channel path.
   Advance to P5 only after the agreed P4 verification gate passes.
