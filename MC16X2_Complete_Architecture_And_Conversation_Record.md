# MC16X2 Memory Controller IP
# Complete Architectural Log, Phase Comparisons, and Implementation Record

---

## 1. Introduction & Context

This document captures the complete technical discussion, architectural analyses, and implementation deliverables for the **MC16X2 Multi-Channel Memory Controller IP**, based on the microarchitecture specification (**Revision 0.4 — Draft for Review**).

### High-Level Specification Summary
* **IP Name**: `MC16X2` (16-Channel / 2-Pseudo-Channel Memory Controller).
* **Standards**: JEDEC JESD238 (HBM3) and DFI 5.0 (adapted to split row/column command buses with embedded pseudo-channel select).
* **Topology**:
  * 16 physical channels, each divided into 2 Pseudo-Channels (**32 independent scheduling domains** total).
  * Single 256-bit AXI4 slave port (`INCR` burst up to 16 beats, posted `bresp`).
  * 16 DFI instances (one shared DFI instance per channel, embedding `pc_sel` in row and col commands, with dedicated 32-bit data lanes per PC).
  * APB4 slave port for 32-bit register configuration with an aggregated `irq` pin.
* **Clock Frequencies**: Fixed 3-domain system:
  * `aclk` = 500 MHz (AXI4 host front-end)
  * `dfi_clk` = 1000 MHz / 1 GHz (Controller core, schedulers, arbiters, formatters, DFI)
  * `pclk` = 50 MHz (APB4 register configuration)
* **Scheduling & Arbitration**: Universal **credit-counter starvation avoidance** (8-bit saturating wait counters, highest counter wins, refresh strictly overrides).
* **Timing Legality**: 1 GHz per-bank and per-PC down-counters (1 cycle = 1.0 ns).
* **Clock Domain Crossing (CDC)**: Confined entirely to the AXI boundary via **5 asynchronous Gray-code FIFOs**; zero CDC logic inside the scheduling core or DFI formatters.

---

## 2. The 4-Phase System: End-to-End Overview

To make the memory controller modular, verifiable, and synthesizable at 1 GHz, the architecture is partitioned into four interconnected phases:

```
                      THE COMPLETE 4-PHASE ARCHITECTURE
                      
 ┌────────────────┐     ┌────────────────┐     ┌────────────────┐     ┌────────────────┐
 │    PHASE P3    │     │    PHASE P1    │     │    PHASE P4    │     │    PHASE P2    │
 │ AXI Front-End  │────►│  Per-PC Core   │────►│ Channel Arbiter│────►│ DFI Formatter  │────► HBM3
 │     & CDC      │     │  (The Brain)   │     │ (Traffic Cop)  │     │  (PHY Output)  │     PHY
 └────────────────┘     └────────────────┘     └────────────────┘     └────────────────┘
      Host AXI           Queues, Banks &         PC0 vs PC1             Physical Pins
      (500 MHz)         DRAM Timing (1 GHz)    Shared Bus (1 GHz)         (1 GHz)
```

### An Intuitive Real-World Analogy: Airport Cargo Terminal
1. **Phase P3 (Customs & Ingest Terminal)**: Receives cargo containers arriving on slower transport ships (`aclk` = 500 MHz), inspects their destination labels (40-bit address decoding), and transfers them onto high-speed conveyor belts (5 Async CDC FIFOs) into the secure sorting hub (`dfi_clk` = 1 GHz).
2. **Phase P1 (The Warehouse Brain — `mc_pc_core`)**: The central scheduling intelligence. Operates 32 independent warehouse bays (one per PC). It manages 16 storage aisles (banks), monitors stopwatches to avoid physical DRAM violations (timing down-counters), and decides which command is legal and ready to issue.
3. **Phase P4 (The Runway Traffic Controller — `mc_ch_arb`)**: Every two warehouse bays (PC0 and PC1) share a single runway (the channel's physical DFI row/col command buses). Phase P4 arbitrates fairly between them using credit counters so neither bay starves, and grants emergency clearance to maintenance vehicles (Refresh).
4. **Phase P2 (The Output Gate — `mc_dfi_fmt`)**: Registers the cleared command on a 1-cycle flop boundary, stamps the flight tag (`pc_sel`), and emits the physical pin signals (`dfi_row`, `dfi_col`, `dfi_wrdata`) to the external HBM3 PHY.

---

## 3. Detailed Architectural Breakdown of Each Phase

### 3.1 Phase P3: Host AXI Front-End & CDC Bridge

#### Functional Responsibilities
* Accepts AXI4 read and write transactions from the SoC interconnect at 500 MHz (`aclk`).
* Decodes the 40-bit address into target Channel (`addr[32:29]`), Pseudo-Channel (`addr[28]`), and bank/row/col fields.
* Bridges transactions across the asynchronous boundary into the 1 GHz `dfi_clk` domain using 5 Gray-coded async FIFOs.
* Implements the **posted `bresp` completion policy**: returns `bvalid`/`bresp` as soon as write data is buffered in the Write Data Buffer (`WDB`) and the command is queued in the `CMDQ`.

#### Address Decoding & Routing Map ([`afe.v`](file:///home/dell/MC16/afe.v))
| Address Bits | Field | Width | Description |
| :---: | :---: | :---: | :--- |
| `[4:0]` | **Byte Offset** | 5 | Byte position within 32-byte AXI beat |
| `[9:5]` | **COL** | 5 | Column address within the active open row |
| `[11:10]` | **BA** | 2 | Bank address within bank group (4 banks) |
| `[13:12]` | **BG** | 2 | Bank group address (4 bank groups) |
| `[27:14]` | **ROW** | 14 | Row address (16,384 rows per bank) |
| `[28]` | **PC_SEL** | 1 | Pseudo-Channel select: `0` = PC0, `1` = PC1 |
| `[32:29]` | **CH_SEL** | 4 | Channel select: Channels 0 to 15 |
| `[39:33]` | **Reserved** | 7 | Must be driven 0 by software |

#### The 5 Async CDC FIFOs ([`mc_axi_cdc.sv`](file:///home/dell/MC16/mc_axi_cdc.sv))
* **AW CDC FIFO** (`aclk` → `dfi_clk`): 72 bits wide × 8 entries (burst metadata).
* **W CDC FIFO** (`aclk` → `dfi_clk`): 289 bits wide × 16 entries (256b data + 32b strb + 1b last; RAM-based).
* **AR CDC FIFO** (`aclk` → `dfi_clk`): 72 bits wide × 8 entries (read metadata).
* **B CDC FIFO** (`dfi_clk` → `aclk`): 10 bits wide × 8 entries (8b BID + 2b BRESP).
* **R CDC FIFO** (`dfi_clk` → `aclk`): 267 bits wide × 16 entries (8b RID + 256b data + 2b RRESP + 1b RLAST; RAM-based).

---

### 3.2 Phase P1: Per-PC Core Architecture (`mc_pc_core`)

Phase P1 is the scheduling core instantiated 32 times (16 channels × 2 PCs). It consists of 7 tightly integrated functional blocks:

```
                            INSIDE mc_pc_core (PHASE P1)
                            
                        From P3 CDC (Core AW/W/AR)
                                    │
            ┌───────────────────────┴───────────────────────┐
            ▼                                               ▼
   ┌─────────────────┐                             ┌─────────────────┐
   │      CMDQ       │                             │       WDB       │
   │  Command Queue  │                             │Write Data Buffer│
   │  (32 entries)   │                             │  (16 entries)   │
   └────────┬────────┘                             └────────┬────────┘
            │                                               │
            │ Decoded Request                               │ (Data ready check)
            ▼                                               │
   ┌────────────────────────────────────────────────────────┴────────┐
   │                      Scheduler & Legality Engine                │
   │                                                                 │
   │   ┌────────────────────┐              ┌─────────────────────┐   │
   │   │  mc_bank_state     │              │  mc_timing_check    │   │
   │   │  (16 Banks:        │              │  (1 GHz Down-       │   │
   │   │   Row Open/Closed) │              │   Counters)         │   │
   │   └─────────┬──────────┘              └──────────┬──────────┘   │
   │             │                                    │              │
   │             ▼                                    ▼              │
   │       Is Bank Open?                       Are Stopwatches 0?    │
   │       (Hit/Miss/Conflict)                 (tRCD, tRP, tRAS, etc)│
   │             │                                    │              │
   │             └─────────────────┬──────────────────┘              │
   │                               ▼                                 │
   │                   Timing-Legal Candidates                       │
   │                               │                                 │
   │                               ▼                                 │
   │                     ┌───────────────────┐                       │
   │                     │    mc_arbiter     │◄── mc_refresh_engine  │
   │                     │  (Credit Counter) │    (tREFI Counter)    │
   │                     └─────────┬─────────┘                       │
   └───────────────────────────────┼─────────────────────────────────┘
                                   │
                   Winning Row & Column Commands
                                   │
                       To Phase P4 (mc_ch_arb)
```

1. **Command Queue (`mc_cmdq`)**: 32 entries. Holds decoded RD/WR requests.
2. **Write Data Buffer (`mc_wdb`)**: 16 entries. Holds write beats until DFI issue.
3. **Read Data Buffer (`mc_rdb`)**: 16 entries. Reassembles DRAM read data for AXI return.
4. **Bank State Table (`mc_bank_state`)**: Tracks 16 banks (4 BG × 4 BA). Resolves **Page Hit**, **Page Empty**, and **Page Conflict**.
5. **Timing-Legality Checker (`mc_timing_check`)**: 1 GHz down-counters enforcing exact JEDEC cycle delays (`tRCD=18`, `tRAS=34`, `tRP=14`, `tRC=50`, `tRRD=6`, `tFAW=32`, `tCCD=4`, `tWTR=8`, `tWR=18`, `tRTP=8`, `tRFC=350`).
6. **Refresh Engine (`mc_refresh_engine`)**: Tracks `tREFI = 3900 ns` (3900 cycles), issuing all-bank `REF` commands with top priority.
7. **Credit-Counter Arbiter (`mc_arbiter`)**: Selects the longest-waiting timing-legal command using 8-bit saturating wait counters.

---

### 3.3 Phase P4: Channel-Level Bus Arbitration (`mc_ch_arb`)

#### Functional Responsibilities
* Couples PC0 and PC1 within each channel to share the channel's single physical row bus and column bus.
* **Dual-Bus Independent Arbitration**: PC0 and PC1 can issue simultaneously if one requests the row bus and the other requests the column bus.
* **Credit-Counter Fairness**: Uses two instances of [`mc_arbiter.sv`](file:///home/dell/MC16/mc_arbiter.sv) with 8-bit saturating counters (`CREDIT_CTR_WIDTH = 8`). Losing candidates increment by `+1` every cycle; granted candidates reset to `0`.
* **Refresh Override**: Any pending refresh automatically wins the bus immediately.
* **Concurrent Data Lanes**: Combines `wrdata_pc0[31:0]` and `wrdata_pc1[31:0]` into `dfi_wrdata[63:0]`, allowing parallel data streaming even when command buses serialize.

---

### 3.4 Phase P2: DFI Output Formatter (`mc_dfi_fmt`)

#### Functional Responsibilities
* Forms the registered output boundary to the external HBM3 PHY at 1 GHz.
* Embeds the `pc_sel` bit into the DFI row and column buses:
  * `dfi_row[21:0] = {row_pc_sel, row_cmd[2:0], row_bg[1:0], row_ba[1:0], row_addr[13:0]}`
  * `dfi_col[11:0] = {col_pc_sel, col_cmd[1:0], col_bg[1:0], col_ba[1:0], col_addr[4:0]}`
* Drives `dfi_row_val` and `dfi_col_val` strobes.
* Demultiplexes returning read data `dfi_rddata[63:0]` into `rddata_pc0[31:0]` and `rddata_pc1[31:0]`.

---

## 4. End-to-End Comparison Matrix (P3 vs. P1 vs. P4 vs. P2)

| Dimension | Phase P3: Host Front-End | Phase P1: Core Scheduler | Phase P4: Channel Arbiter | Phase P2: DFI Formatter |
| :--- | :--- | :--- | :--- | :--- |
| **Primary RTL** | [`mc_axi_cdc.sv`](file:///home/dell/MC16/mc_axi_cdc.sv), [`afe.v`](file:///home/dell/MC16/afe.v) | `mc_pc_core.sv` (`mc_cmdq`, `mc_bank_state`) | [`mc_ch_arb.sv`](file:///home/dell/MC16/mc_ch_arb.sv), [`mc_arbiter.sv`](file:///home/dell/MC16/mc_arbiter.sv) | [`mc_dfi_fmt.sv`](file:///home/dell/MC16/mc_dfi_fmt.sv) |
| **Clock Domain** | `aclk` (500 MHz) ↔ `dfi_clk` (1 GHz) | `dfi_clk` (1 GHz, synchronous) | `dfi_clk` (1 GHz, synchronous) | `dfi_clk` (1 GHz, synchronous) |
| **Instance Count** | **1 Global Port** | **32 Instances** (16 CH × 2 PC) | **16 Instances** (1 per Channel) | **16 Instances** (1 per Channel) |
| **Core Function** | Protocol conversion, CDC, posted `bresp` | Bank tracking, JEDEC timing legality | Arbitrating shared command buses | Pin vector packing, embedding `pc_sel` |
| **Data Width** | **256 bits** (AXI beat) | **32 bits** (PC stream) | **64 bits** (32b PC0 + 32b PC1) | **64 bits** (DFI physical bus) |
| **Arbitration Scope**| None (FIFO backpressure) | Internal CMDQ candidates | Channel level (PC0 vs PC1) | None (Registered pipeline stage) |
| **Timing Checks** | AXI valid/ready handshakes | JEDEC down-counters (`tRCD`, `tRP`, etc.) | Assumes inputs are legal | PHY delays (`tphy_wrlat`, `tphy_rdlat`)|

---

## 5. Summary of Workspace Implementation Status

The workspace `/home/dell/MC16` currently contains:
1. **[`cdc_sync_2ff.sv`](file:///home/dell/MC16/cdc_sync_2ff.sv)**: Parameterized 2-FF Gray pointer synchronizer with `// CDC_MODULE` lint tag.
2. **[`async_fifo.sv`](file:///home/dell/MC16/async_fifo.sv)**: Parameterized dual-clock FIFO with Gray-code pointers, FWFT support, and occupancy tracking.
3. **[`mc_axi_cdc.sv`](file:///home/dell/MC16/mc_axi_cdc.sv)**: AXI-to-Core CDC bridge instantiating all 5 async FIFOs (AW, W, AR, B, R).
4. **[`afe.v`](file:///home/dell/MC16/afe.v)**: Fixed 40-bit address decoder and per-channel/per-PC router.
5. **[`mc_arbiter.sv`](file:///home/dell/MC16/mc_arbiter.sv)**: 2-candidate credit-counter arbiter with saturating wait counters and refresh override.
6. **[`mc_ch_arb.sv`](file:///home/dell/MC16/mc_ch_arb.sv)**: Channel arbiter integrating row/col bus arbiters and 32b/64b data path aggregation.
7. **[`mc_dfi_fmt.sv`](file:///home/dell/MC16/mc_dfi_fmt.sv)**: DFI 5.0 output formatting stage.
8. **[`tb_mc_axi_cdc.sv`](file:///home/dell/MC16/tb_mc_axi_cdc.sv)**, **[`tb_mc_ch_arb.sv`](file:///home/dell/MC16/tb_mc_ch_arb.sv)**, **[`tb_dfi_formatter.sv`](file:///home/dell/MC16/tb_dfi_formatter.sv)**: Unit testbenches for verification.
