# uart_tx — UART Transmitter

A UART Transmitter implemented in SystemVerilog.
Transmits 8-bit data serially at **9600 baud** over a 50 MHz system clock (8N1 framing).
Run it instantly on **EDA Playground**: [https://edaplayground.com/x/ts3j](https://edaplayground.com/x/ts3j)

---

## Repository Layout

```
.
├── design.sv       # DUT  – UART TX module (uart_tx)
└── testbench.sv    # TB   – directed test (tb_uart_tx)
```

---

## DUT — `uart_tx`

### Specifications

| Parameter        | Value             |
|------------------|-------------------|
| Clock Frequency  | 50 MHz            |
| Baud Rate        | 9600              |
| Data Bits        | 8                 |
| Start Bits       | 1                 |
| Stop Bits        | 1                 |
| Parity           | None (8N1)        |
| Baud Divisor     | 5208 cycles / bit |

### Ports

| Port       | Dir | Width | Description                                    |
|------------|-----|-------|------------------------------------------------|
| `clk`      | in  | 1     | System clock (50 MHz, active rising edge)      |
| `rst_n`    | in  | 1     | Active-low synchronous reset                   |
| `tx_start` | in  | 1     | Pulse high for one cycle to begin transmission |
| `tx_data`  | in  | 8     | Byte to transmit (captured on `tx_start`)      |
| `tx`       | out | 1     | Serial output line (idle HIGH)                 |
| `tx_busy`  | out | 1     | HIGH while a frame is in progress              |

### Implementation Notes

- Baud rate generator: a free-running counter counts to `CLK_FREQ / BAUD_RATE − 1` (5207) to produce one-bit clock ticks.
- Data is shifted out **LSB first** as required by the UART standard.
- `tx_busy` prevents a new `tx_start` from being accepted mid-frame.

---

## FSM

The transmitter is controlled by a 4-state FSM:

```
          tx_start & !tx_busy
  IDLE ─────────────────────► START
   ▲                             │  (1 bit period — line LOW)
   │                             ▼
  STOP ◄──────────────────── DATA
  (1 bit period — line HIGH)   (8 bit periods — LSB first)
             all bits sent
```

| State   | `tx` value | Next condition                      |
|---------|------------|-------------------------------------|
| `IDLE`  | `1`        | `tx_start` asserted                 |
| `START` | `0`        | One bit period elapsed              |
| `DATA`  | `bit[i]`   | All 8 bits shifted; last bit period |
| `STOP`  | `1`        | One bit period elapsed → IDLE       |

---

## Test Cases

Three directed tests are run back-to-back in `tb_uart_tx`:

| #  | Value  | Bit Pattern | Purpose                          |
|----|--------|-------------|----------------------------------|
| 1  | `0x41` | `0100 0001` | ASCII `'A'` — typical character  |
| 2  | `0xFF` | `1111 1111` | All ones — max value stress test |
| 3  | `0x00` | `0000 0000` | All zeros — min value stress test|

Each test asserts `tx_start` for one cycle, then waits for `tx_busy` to deassert before triggering the next transmission.

---

## Running on EDA Playground

1. Open [https://edaplayground.com/x/ts3j](https://edaplayground.com/x/ts3j)
2. Select **Icarus Verilog** (or any SystemVerilog-capable simulator) under *Tools & Simulators*.
3. Click **Run** — the log and EPWave VCD dump are available in the output tabs.

### Local Simulation (Icarus Verilog)

```bash
iverilog -g2012 -o uart_sim design.sv testbench.sv
vvp uart_sim
```

### Local Simulation (Questa / ModelSim)

```bash
vlog -sv design.sv testbench.sv
vsim -c tb_uart_tx -do "run -all; quit"
```

---

## Extending the Design

| Goal | Where to change |
|------|-----------------|
| Change baud rate | Update `BAUD_RATE` parameter in `uart_tx` |
| Change clock frequency | Update `CLK_FREQ` parameter in `uart_tx` |
| Add parity bit | Insert a `PARITY` state between `DATA` and `STOP` |
| Add a receiver | Create a companion `uart_rx` module with matching baud divisor |
| Add more test vectors | Append `tx_start` stimulus blocks in `tb_uart_tx` |

---

## Author

**Atiqur Rahman Sajib**

---

## License

This project is provided as an educational example. Use freely for learning and adaptation.
