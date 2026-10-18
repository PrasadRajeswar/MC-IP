# MC16X2 Memory Controller IP
## Architectural Review, P2 vs. P3 Relationship, and Phase P3 CDC Implementation

---

## 1. Context & Architectural Overview

The **MC16X2** is a multi-channel memory controller IP designed to connect an SoC master to an **HBM3 (JESD238)** memory stack through a **DFI 5.0 PHY interface**.

### Key Architectural Pillars (Spec Rev 0.4)
* **Memory Organization**: 16 physical channels, each divided into 2 Pseudo-Channels (**32 independent scheduling domains** total).
* **Clocking Structure**:
  * `aclk` = 500 MHz (AXI4 slave front-end)
  * `dfi_clk` = 1000 MHz / 1 GHz (Controller core, schedulers, arbiters, formatters, DFI)
  * `pclk` = 50 MHz (APB4 register configuration)
* **Host Interface**: Single 256-bit AXI4 slave port (`INCR` burst up to 16 beats, posted `bresp`).
* **PHY Interface**: 16 DFI instances (one per channel). PC0 and PC1 share the channel's row/col command buses with an embedded `pc_sel` bit, with independent 32-bit data lanes on a combined 64-bit DFI data bus.
* **Scheduling Mechanism**: Universal **credit-counter starvation avoidance** (8-bit saturating wait counters, highest counter wins, refresh always wins).
* **Timing Legality**: Per-bank and per-PC down-counters operating at 1 GHz (1 cycle = 1.0 ns).

---

## 2. Core Relationship Between Phase P2 and Phase P3

Phase P2 (**DFI Formatter**) and Phase P3 (**AXI Front-End + CDC**) form the **two boundary bookends** of the memory controller.

```
                      Phase P3 (Front-End)                                             Phase P2 (Back-End)
          ┌──────────────────────────────────────────┐                     ┌────────────────────────────────────────┐
SoC Host  │ • AXI4 Slave Protocol Handler            │   Core Scheduling   │ • Channel DFI Formatter (mc_dfi_fmt)   │ HBM3
Interconnect│ • 40-bit Address Bit-Slice (afe.v)       ├──► Pipeline ───────►│ • Embeds pc_sel into dfi_row/dfi_col  │► PHY &
 (aclk:   │ • 5 Async CDC FIFOs (aclk ↔ dfi_clk)     │   (CMDQ / WDB /     │ • 64b Data (32b PC0 + 32b PC1)         │ DRAM
 500 MHz) │ • APB4 CSR Configuration & IRQ Bridge    │    Arbitration)     │ • PHY Latency Alignment (tphy_wrlat)  │ (dfi_clk:
          └──────────────────────────────────────────┘                     └────────────────────────────────────────┘  1 GHz)
```

### 2.1 Theoretical Comparison

| Architectural Dimension | Phase P3: Host Ingress / Egress | Phase P2: PHY Egress / Ingress | Theoretical Significance |
| :--- | :--- | :--- | :--- |
| **Pipeline Position** | **Northbound Ingress/Egress** (SoC-facing) | **Southbound Egress/Ingress** (PHY-facing) | Physical boundaries of the entire IP. |
| **Abstraction Level** | **Transaction-based**: Operates on AXI bursts (1–16 beats), 40-bit address spaces, and burst types. | **Cycle-accurate physical signaling**: Translates commands into pin-level row/col strobes (`ACT`, `PRE`, `RD`, `WR`). | P3 digests abstract host requests; P2 emits physical DRAM commands. |
| **Bandwidth & Topology** | **Funnel**: Single 256-bit port @ 500 MHz = **128 Gbps**. | **Fan-out**: 16 channel instances @ 1 GHz (64b each) = **1024 Gbps aggregate**. | P3 acts as the central funnel routing traffic across 16 independent P2 PHY slices. |
| **Clocking Context** | **Asynchronous Boundary**: Crosses `aclk` (500 MHz) ↔ `dfi_clk` (1 GHz) via 5 async FIFOs. | **Fully Synchronous**: Runs purely in `dfi_clk` (1 GHz) with 1 ns cycle accuracy. | P3 isolates the core from SoC clock variability; P2 matches DRAM cycle resolution. |
| **Completion Model** | **Posted Completion**: Issues `bresp` as soon as write data is buffered in WDB/CMDQ. | **Actual DRAM Commit**: Drives write data `tphy_wrlat` cycles after command. | P3 decouples SoC write latency from the physical DRAM write timeline governed by P2. |

---

### 2.2 Code-Wise Comparison

The data structures in P3 directly define the bit payloads formatted onto physical wires in P2.

#### 1. Address Bit-Slice Correspondence
P3 extracts the 40-bit AXI address into fields that P2 reconstructs directly onto the DFI buses:

```
  40-bit AXI Host Address (P3 / afe.v)
  ┌──────────┬────────┬────────┬────────────────┬──────────┬──────────┬──────────┬─────────────┐
  │ [39:33]  │[32:29] │  [28]  │    [27:14]     │ [13:12]  │ [11:10]  │  [9:5]   │    [4:0]    │
  │ Reserved │ CH_SEL │ PC_SEL │    ROW ADDR    │    BG    │    BA    │   COL    │ Byte Offset │
  └──────────┴───┬────┴───┬────┴───────┬────────┴────┬─────┴────┬─────┴────┬─────┴─────────────┘
                 │        │            │             │          │          │
                 │        │            ▼             ▼          ▼          ▼
                 │        │     ┌────────────────────────────────────────────┐
                 │        └────►│ dfi_row [21:0] (P2 / mc_dfi_fmt.sv)        │
                 │              │ {pc_sel, row_cmd[2:0], bg, ba, row_addr}   │
                 │              └────────────────────────────────────────────┘
                 │        │                          ▲          ▲          ▲
                 │        └──────────────────────────┼──────────┼──────────┤
                 │                                   ▼          ▼          ▼
                 │              ┌────────────────────────────────────────────┐
                 │              │ dfi_col [11:0] (P2 / mc_dfi_fmt.sv)        │
                 │              │ {pc_sel, col_cmd[1:0], bg, ba, col_addr}   │
                 │              └────────────────────────────────────────────┘
                 ▼
     Selects 1 of 16 Channels
     (mc_dfi_fmt [0:15])
```

#### Code Side-by-Side:
```systemverilog
// --- Phase P3: Address Decoding (afe.v) ---
assign ch_sel      = addr[32:29]; // Selects 1 of 16 P2 instances (mc_dfi_fmt [0:15])
assign pc_sel      = addr[28];    // Selects PC0 or PC1 within that channel
assign row         = addr[27:14]; // 14-bit row address
assign bg          = addr[13:12]; // 2-bit bank group
assign ba          = addr[11:10]; // 2-bit bank
assign col         = addr[9:5];   // 5-bit column address
assign byte_offset = addr[4:0];   // 32-byte beat offset

// --- Phase P2: DFI Bus Packing (mc_dfi_fmt.sv) ---
// Row Bus (22b): {pc_sel, row_cmd, bg, ba, row_addr}
dfi_row <= {row_pc_sel, row_cmd, row_bg, row_ba, row_addr};

// Col Bus (12b): {pc_sel, col_cmd, bg, ba, col_addr}
dfi_col <= {col_pc_sel, col_cmd, col_bg, col_ba, col_addr};
```

#### 2. Data Bus Width Alignment (256b Host vs. 32b/64b DFI)
* **P3**: Accepts 256-bit write beats (`s_axi_wdata[255:0]`) with 32-bit byte strobes (`s_axi_wstrb[31:0]`).
* **P2**: Drives a 64-bit channel data bus (`dfi_wrdata[63:0]`), split into:
  * `[31:0]` dedicated to PC0
  * `[63:32]` dedicated to PC1
* One 256-bit AXI beat decoded by P3 for a given PC is serialized by the core into **eight 32-bit transfers** over that PC's lane in P2.

#### 3. Posted Completion vs. Physical DRAM Commit
* **P3 Completion**: AXI `bresp` is **posted**; it is asserted once write data is buffered into the WDB and CMDQ enqueues the request.
* **P2 Completion**: The write command is sent over `dfi_col` and write data driven `tphy_wrlat` cycles later. If physical DFI errors occur after `bresp` has posted, P3 cannot alter `bresp`; the failure must be converted to an APB interrupt (`irq`).

---

## 3. Phase P3 RTL Implementation Progress

To establish the Phase P3 front-end and CDC bridge, three modules and a comprehensive testbench were developed:

### 3.1 [`cdc_sync_2ff.sv`](file:///home/dell/MC16/cdc_sync_2ff.sv)
* Implements a parameterized 2-flip-flop synchronizer chain.
* Tagged with `// CDC_MODULE` and `(* ASYNC_REG = "TRUE" *)` for synthesis/lint tools.
* Asynchronous reset for metastability resolution on reset assertion.

### 3.2 [`async_fifo.sv`](file:///home/dell/MC16/async_fifo.sv)
* Dual-clock asynchronous FIFO with Gray-code pointer synchronization.
* **Features**:
  * Parameterized `DATA_WIDTH`, `DEPTH` (power of 2), and `SYNC_STAGES`.
  * First-Word Fall-Through (FWFT) ready/valid handshaking.
  * Synchronous dual-port RAM storage.
  * Real-time occupancy calculation (`wcount` in write domain, `rcount` in read domain) by converting synchronized Gray pointers back to binary.

### 3.3 [`mc_axi_cdc.sv`](file:///home/dell/MC16/mc_axi_cdc.sv)
Implements all 5 asynchronous FIFOs specified in Section 6.2:

| FIFO Name | Direction | Data Width | Depth | Payload Contents |
| :--- | :---: | :---: | :---: | :--- |
| **AW CDC FIFO** | `aclk` → `dfi_clk` | 72 bits | 8 | `awid[7:0]`, `awlen[7:0]`, `awsize[2:0]`, `awburst[1:0]`, `awaddr[39:0]`, `awqos[3:0]`, `awcache[3:0]`, `awprot[2:0]` |
| **W CDC FIFO** | `aclk` → `dfi_clk` | 289 bits | 16 | `wdata[255:0]`, `wstrb[31:0]`, `wlast[0]` (RAM-based FIFO) |
| **AR CDC FIFO** | `aclk` → `dfi_clk` | 72 bits | 8 | `arid[7:0]`, `arlen[7:0]`, `arsize[2:0]`, `arburst[1:0]`, `araddr[39:0]`, `arqos[3:0]`, `arcache[3:0]`, `arprot[2:0]` |
| **B CDC FIFO** | `dfi_clk` → `aclk` | 10 bits | 8 | `bid[7:0]`, `bresp[1:0]` (posted response) |
| **R CDC FIFO** | `dfi_clk` → `aclk` | 267 bits | 16 | `rid[7:0]`, `rdata[255:0]`, `rresp[1:0]`, `rlast[0]` (RAM-based FIFO) |

Exposes real-time occupancy ports for CSR monitoring.

### 3.4 [`afe.v`](file:///home/dell/MC16/afe.v) Cleanup
* Fixed syntax issues in `mc_ch_pc_router` array initialization to ensure broad compiler compatibility (Icarus, Verilator, VCS, Questa).
* Cleaned out non-synthesizable text annotations.

---

## 4. Verification Analysis ([`tb_mc_axi_cdc.sv`](file:///home/dell/MC16/tb_mc_axi_cdc.sv))

The testbench tests cross-clock operations between `aclk` (500 MHz, 2.0 ns period) and `dfi_clk` (1 GHz, 1.0 ns period, 350 ps phase skew):

### Key Observations & Synchronization Nuances
1. **Clock Ratio Speed Asymmetry**:
   * The core clock (`dfi_clk`) runs at **twice the frequency** of the host clock (`aclk`).
   * When popping data in the faster domain (`dfi_clk`), pointer synchronization back to the slower domain (`aclk`) requires 2-3 `aclk` cycles (4-6 ns).
2. **Backpressure & Full Behavior**:
   * On FIFO fill, `wfull` asserts and `s_axi_wready` deasserts. When testing burst capacity in a testbench, the driver must verify that the 16th beat asserts `wfull` without attempting a 17th cycle when `wready` is low.
3. **FWFT Handshaking in TB**:
   * Under FWFT semantics, `rdata` updates concurrently when `rready && rvalid` handshakes. Testbench checks should inspect `rdata` during the active cycle of the handshake.

---

## 5. Next Steps for Phase P3

1. **Testbench Tuning**: Adjust `tb_mc_axi_cdc.sv` handshake timing in Test 2, Test 5, and Test 6 to verify clean full-capacity and burst transfers.
2. **Front-End Protocol Handler (`mc_axi_sub.sv`)**:
   * AXI4 subordinate handshake sequencer.
   * Legality checker (enforce `INCR` bursts only, burst length ≤ 16, reject `WRAP`/`FIXED` with `DECERR`).
   * Posted `bresp` generation upon WDB enqueue.
3. **APB4 CSR Block (`mc_csr.sv`)**:
   * 32-bit register address decoder (`pclk` @ 50 MHz).
   * 2-FF synchronizer pulse generation for CSR updates across `pclk` ↔ `dfi_clk`.
   * Readback multiplexer for FIFO occupancy registers and error flags.
