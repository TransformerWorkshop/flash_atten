"""
PYNQ test script for csr_array AXI4-Lite registers.

Usage (on PYNQ board):
    python3 test_csr_array.py --bitstream /path/to/design.bit --base-addr 0x40000000

The script writes every R/W register, reads it back, and verifies the value.
Read-only registers (STATUS, CYCLES) are also sampled.
"""

import argparse
import sys

from pynq import Overlay, MMIO

# ---------------------------------------------------------------------------
# Register map  (must match rtl/csr_array.v)
# ---------------------------------------------------------------------------
REG_MAP = {
    "CTRL":         0x00,
    "STATUS":       0x04,
    "CFG":          0x08,
    "Q_BASE_L":     0x14,
    "Q_BASE_H":     0x18,
    "K_BASE_L":     0x1C,
    "K_BASE_H":     0x20,
    "V_BASE_L":     0x24,
    "V_BASE_H":     0x28,
    "O_BASE_L":     0x2C,
    "O_BASE_H":     0x30,
    "STRIDE_BYTES": 0x34,
    "NEG_LARGE":    0x38,
    "SCALE":        0x3C,
    "CYCLES":       0x40,
}

RW_REGS = [
    "CTRL", "CFG",
    "Q_BASE_L", "Q_BASE_H",
    "K_BASE_L", "K_BASE_H",
    "V_BASE_L", "V_BASE_H",
    "O_BASE_L", "O_BASE_H",
    "STRIDE_BYTES", "NEG_LARGE", "SCALE",
]

RO_REGS = ["STATUS", "CYCLES"]

ADDR_RANGE = 0x44  # span covers 0x00–0x40 inclusive + 4


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def reg_write(mmio: MMIO, name: str, value: int) -> None:
    mmio.write(REG_MAP[name], value)


def reg_read(mmio: MMIO, name: str) -> int:
    return mmio.read(REG_MAP[name])


def check(name: str, expected: int, actual: int) -> bool:
    if expected != actual:
        print(f"  [FAIL] {name}: wrote 0x{expected:08X}, read 0x{actual:08X}")
        return False
    print(f"  [PASS] {name}: 0x{actual:08X}")
    return True


# ---------------------------------------------------------------------------
# Test: reset values
# ---------------------------------------------------------------------------
def test_reset_values(mmio: MMIO) -> int:
    """After loading the overlay all R/W registers should read 0."""
    print("\n=== Test: Reset Values ===")
    fails = 0
    for name in RW_REGS:
        val = reg_read(mmio, name)
        if not check(name, 0x0000_0000, val):
            fails += 1
    return fails


# ---------------------------------------------------------------------------
# Test: write / read-back every R/W register
# ---------------------------------------------------------------------------
def test_write_readback(mmio: MMIO) -> int:
    """Write a known pattern to each R/W register and read it back."""
    print("\n=== Test: Write / Read-back ===")
    fails = 0

    patterns = [0xDEAD_BEEF, 0x1234_5678, 0x0000_0001, 0xFFFF_FFFF, 0x0000_0000]

    for pat in patterns:
        print(f"  -- pattern 0x{pat:08X} --")
        for name in RW_REGS:
            reg_write(mmio, name, pat)

        for name in RW_REGS:
            val = reg_read(mmio, name)
            if not check(name, pat, val):
                fails += 1

    return fails


# ---------------------------------------------------------------------------
# Test: individual register isolation
# ---------------------------------------------------------------------------
def test_register_isolation(mmio: MMIO) -> int:
    """Writing one register must not affect its neighbours."""
    print("\n=== Test: Register Isolation ===")
    fails = 0

    # Clear all
    for name in RW_REGS:
        reg_write(mmio, name, 0x0000_0000)

    for target in RW_REGS:
        reg_write(mmio, target, 0xA5A5_A5A5)
        for name in RW_REGS:
            val = reg_read(mmio, name)
            expected = 0xA5A5_A5A5 if name == target else 0x0000_0000
            if not check(f"{target}->{name}", expected, val):
                fails += 1
        reg_write(mmio, target, 0x0000_0000)

    return fails


# ---------------------------------------------------------------------------
# Test: CTRL bit-fields
# ---------------------------------------------------------------------------
def test_ctrl_bits(mmio: MMIO) -> int:
    """Verify START, SOFT_RESET, IRQ_EN bits in CTRL register."""
    print("\n=== Test: CTRL Bit-fields ===")
    fails = 0

    # bit0 = START
    reg_write(mmio, "CTRL", 0x0000_0001)
    val = reg_read(mmio, "CTRL")
    if not check("CTRL.START", 0x0000_0001, val):
        fails += 1

    # bit1 = SOFT_RESET
    reg_write(mmio, "CTRL", 0x0000_0002)
    val = reg_read(mmio, "CTRL")
    if not check("CTRL.SOFT_RESET", 0x0000_0002, val):
        fails += 1

    # bit2 = IRQ_EN
    reg_write(mmio, "CTRL", 0x0000_0004)
    val = reg_read(mmio, "CTRL")
    if not check("CTRL.IRQ_EN", 0x0000_0004, val):
        fails += 1

    # all three
    reg_write(mmio, "CTRL", 0x0000_0007)
    val = reg_read(mmio, "CTRL")
    if not check("CTRL.ALL", 0x0000_0007, val):
        fails += 1

    # clean up
    reg_write(mmio, "CTRL", 0x0000_0000)
    return fails


# ---------------------------------------------------------------------------
# Test: CFG bit-fields
# ---------------------------------------------------------------------------
def test_cfg_bits(mmio: MMIO) -> int:
    """Verify CAUSAL_EN bit in CFG register."""
    print("\n=== Test: CFG Bit-fields ===")
    fails = 0

    reg_write(mmio, "CFG", 0x0000_0001)
    val = reg_read(mmio, "CFG")
    if not check("CFG.CAUSAL_EN", 0x0000_0001, val):
        fails += 1

    reg_write(mmio, "CFG", 0x0000_0000)
    val = reg_read(mmio, "CFG")
    if not check("CFG.CAUSAL_EN=0", 0x0000_0000, val):
        fails += 1

    return fails


# ---------------------------------------------------------------------------
# Test: 64-bit base address composition
# ---------------------------------------------------------------------------
def test_64bit_addresses(mmio: MMIO) -> int:
    """Write split high/low and verify the full 64-bit address."""
    print("\n=== Test: 64-bit Address Composition ===")
    fails = 0

    bases = {
        "Q_BASE": (0xDEAD_BEEF, 0x0102_0304),
        "K_BASE": (0x1111_2222, 0x3333_4444),
        "V_BASE": (0xAAAA_BBBB, 0xCCCC_DDDD),
        "O_BASE": (0x5555_6666, 0x7777_8888),
    }

    for base_name, (low, high) in bases.items():
        reg_write(mmio, f"{base_name}_L", low)
        reg_write(mmio, f"{base_name}_H", high)

    for base_name, (low, high) in bases.items():
        rd_l = reg_read(mmio, f"{base_name}_L")
        rd_h = reg_read(mmio, f"{base_name}_H")
        addr64 = (rd_h << 32) | rd_l
        expected = (high << 32) | low
        if not check(f"{base_name} (64-bit)", expected, addr64):
            fails += 1

    return fails


# ---------------------------------------------------------------------------
# Test: read-only register sampling
# ---------------------------------------------------------------------------
def test_read_only(mmio: MMIO) -> int:
    """Read STATUS and CYCLES (read-only). Just check they are accessible."""
    print("\n=== Test: Read-Only Registers ===")
    fails = 0
    for name in RO_REGS:
        val = reg_read(mmio, name)
        print(f"  [INFO] {name}: 0x{val:08X}")
    return fails


# ---------------------------------------------------------------------------
# Test: STATUS should not be writable
# ---------------------------------------------------------------------------
def test_status_not_writable(mmio: MMIO) -> int:
    """Attempt to write STATUS; the RTL should ignore it."""
    print("\n=== Test: STATUS Not Writable ===")
    fails = 0
    before = reg_read(mmio, "STATUS")
    reg_write(mmio, "STATUS", 0xFFFF_FFFF)
    after = reg_read(mmio, "STATUS")
    if before != after:
        print(f"  [FAIL] STATUS changed: before=0x{before:08X} after=0x{after:08X}")
        fails += 1
    else:
        print(f"  [PASS] STATUS unchanged: 0x{after:08X}")
    return fails


# ---------------------------------------------------------------------------
# Dump all registers
# ---------------------------------------------------------------------------
def dump_all(mmio: MMIO) -> None:
    """Print the current value of every register."""
    print("\n=== Register Dump ===")
    for name in sorted(REG_MAP, key=lambda n: REG_MAP[n]):
        val = reg_read(mmio, name)
        print(f"  0x{REG_MAP[name]:02X}  {name:16s} = 0x{val:08X}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(description="PYNQ CSR-array register test")
    parser.add_argument(
        "--bitstream", "-b", required=True,
        help="Path to the .bit bitstream file",
    )
    parser.add_argument(
        "--base-addr", "-a", default="0x40000000",
        help="AXI base address of the csr_array IP (hex, default 0x40000000)",
    )
    args = parser.parse_args()

    base_addr = int(args.base_addr, 16)

    print(f"Loading overlay: {args.bitstream}")
    ol = Overlay(args.bitstream)

    print(f"Creating MMIO at base 0x{base_addr:08X}, range 0x{ADDR_RANGE:02X}")
    mmio = MMIO(base_addr, ADDR_RANGE)

    total_fails = 0
    total_fails += test_reset_values(mmio)
    total_fails += test_write_readback(mmio)
    total_fails += test_register_isolation(mmio)
    total_fails += test_ctrl_bits(mmio)
    total_fails += test_cfg_bits(mmio)
    total_fails += test_64bit_addresses(mmio)
    total_fails += test_read_only(mmio)
    total_fails += test_status_not_writable(mmio)

    dump_all(mmio)

    print("\n" + "=" * 50)
    if total_fails == 0:
        print("ALL TESTS PASSED")
    else:
        print(f"TOTAL FAILURES: {total_fails}")
    print("=" * 50)

    sys.exit(1 if total_fails else 0)


if __name__ == "__main__":
    main()
