from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Tuple


@dataclass(frozen=True)
class WindowedRtlContractConfig:
    seq_len: int = 256
    head_dim: int = 64
    q_group_rows: int = 64
    q_tile_rows: int = 4
    state_group_rows: int = 4
    kv_tile_rows: int = 16
    kv_window_tiles: int = 4
    k_sram_macro_count: int = 8
    v_sram_macro_count: int = 8
    oacc_sram_macro_count: int = 4
    oacc_sram_data_width: int = 64
    q_tile_beat_count: int = 64
    k_tile_beat_count: int = 256
    v_tile_beat_count: int = 256
    micro_tiles_per_core_start: int = 4
    qk_tasks_per_micro_tile: int = 128
    pv_tasks_per_micro_tile: int = 128
    causal: bool = False

    def validate(self) -> None:
        positive_fields = {
            "seq_len": self.seq_len,
            "head_dim": self.head_dim,
            "q_group_rows": self.q_group_rows,
            "q_tile_rows": self.q_tile_rows,
            "state_group_rows": self.state_group_rows,
            "kv_tile_rows": self.kv_tile_rows,
            "kv_window_tiles": self.kv_window_tiles,
            "k_sram_macro_count": self.k_sram_macro_count,
            "v_sram_macro_count": self.v_sram_macro_count,
            "oacc_sram_macro_count": self.oacc_sram_macro_count,
            "oacc_sram_data_width": self.oacc_sram_data_width,
            "q_tile_beat_count": self.q_tile_beat_count,
            "k_tile_beat_count": self.k_tile_beat_count,
            "v_tile_beat_count": self.v_tile_beat_count,
            "micro_tiles_per_core_start": self.micro_tiles_per_core_start,
            "qk_tasks_per_micro_tile": self.qk_tasks_per_micro_tile,
            "pv_tasks_per_micro_tile": self.pv_tasks_per_micro_tile,
        }
        for name, value in positive_fields.items():
            if value <= 0:
                raise ValueError(f"{name} must be positive")
        if self.seq_len % self.q_group_rows != 0:
            raise ValueError("seq_len must be divisible by q_group_rows")
        if self.q_group_rows % self.q_tile_rows != 0:
            raise ValueError("q_group_rows must be divisible by q_tile_rows")
        if self.q_group_rows % self.state_group_rows != 0:
            raise ValueError("q_group_rows must be divisible by state_group_rows")
        if self.state_group_rows % self.q_tile_rows != 0:
            raise ValueError("state_group_rows must be divisible by q_tile_rows")
        if self.seq_len % self.kv_tile_rows != 0:
            raise ValueError("seq_len must be divisible by kv_tile_rows")
        if (self.seq_len // self.kv_tile_rows) % self.kv_window_tiles != 0:
            raise ValueError("KV tile count must be divisible by kv_window_tiles")

    @property
    def total_sram_macro_count(self) -> int:
        return (
            self.k_sram_macro_count
            + self.v_sram_macro_count
            + self.oacc_sram_macro_count
        )


@dataclass(frozen=True)
class WindowedTopAxiLayoutConfig:
    q_base: int = 0x0000_1000
    k_base: int = 0x0001_0000
    v_base: int = 0x0002_0000
    o_base: int = 0x0003_0000
    q_tile_bytes: int = 512
    kv_tile_bytes: int = 2048
    axi_beat_bytes: int = 16
    max_burst_beats: int = 16


@dataclass(frozen=True)
class WindowedTopAxiReadMetrics:
    ar_count: int
    r_beat_count: int
    rd_bytes: int


@dataclass(frozen=True)
class WindowedTopAxiWriteMetrics:
    aw_count: int
    w_beat_count: int
    wr_bytes: int


@dataclass(frozen=True)
class WindowedRtlCounters:
    q_group_count: int
    kv_window_count: int
    q_tile_visit_count: int
    q_tile_req_count: int
    q_tile_beat_count: int
    k_tile_req_count: int
    k_tile_beat_count: int
    v_tile_req_count: int
    v_tile_beat_count: int
    micro_tile_count: int
    kv_tile_count: int
    state_fill_count: int
    state_spill_count: int
    state_restore_count: int
    oacc_restore_cycle_count: int
    oacc_spill_cycle_count: int
    core_start_count: int
    restore_start_count: int
    qk_task_count: int
    pv_task_count: int
    oacc_task_count: int
    skipped_future_kv_tiles: int


@dataclass(frozen=True)
class CoreStartEvent:
    q_group_idx: int
    kv_window_idx: int
    q_tile_in_group_idx: int
    q_tile_idx: int
    kv_base_idx: int
    restore: bool


@dataclass(frozen=True)
class WindowedRtlContract:
    config: WindowedRtlContractConfig
    counters: WindowedRtlCounters
    q_tile_requests: List[int]
    k_tile_requests: List[int]
    v_tile_requests: List[int]
    core_starts: List[CoreStartEvent]


def build_windowed_rtl_contract(
    cfg: WindowedRtlContractConfig,
) -> WindowedRtlContract:
    cfg.validate()
    q_group_count = cfg.seq_len // cfg.q_group_rows
    q_tiles_per_group = cfg.q_group_rows // cfg.q_tile_rows
    state_groups_per_q_group = cfg.q_group_rows // cfg.state_group_rows
    kv_tile_count = cfg.seq_len // cfg.kv_tile_rows
    kv_windows_per_group = kv_tile_count // cfg.kv_window_tiles

    q_tile_requests: List[int] = []
    k_tile_requests: List[int] = []
    v_tile_requests: List[int] = []
    core_starts: List[CoreStartEvent] = []

    for q_group_idx in range(q_group_count):
        for kv_window_idx in range(kv_windows_per_group):
            if _causal_window_fully_future(cfg, q_group_idx, kv_window_idx):
                continue
            kv_base_idx = kv_window_idx * cfg.kv_window_tiles
            for slot_idx in range(cfg.kv_window_tiles):
                kv_tile_idx = kv_base_idx + slot_idx
                k_tile_requests.append(kv_tile_idx)
                v_tile_requests.append(kv_tile_idx)
            for q_tile_in_group_idx in range(q_tiles_per_group):
                q_tile_idx = (q_group_idx * q_tiles_per_group) + q_tile_in_group_idx
                q_tile_requests.append(q_tile_idx)
                core_starts.append(
                    CoreStartEvent(
                        q_group_idx=q_group_idx,
                        kv_window_idx=kv_window_idx,
                        q_tile_in_group_idx=q_tile_in_group_idx,
                        q_tile_idx=q_tile_idx,
                        kv_base_idx=kv_base_idx,
                        restore=(kv_window_idx != 0),
                    )
                )

    core_start_count = len(core_starts)
    micro_tile_count = sum(_micro_tiles_for_event(cfg, event) for event in core_starts)
    full_schedule_micro_tiles = (
        q_group_count
        * kv_windows_per_group
        * q_tiles_per_group
        * cfg.micro_tiles_per_core_start
    )
    skipped_future_kv_tiles = full_schedule_micro_tiles - micro_tile_count
    state_fill_count = sum(
        state_groups_per_q_group
        for q_group_idx in range(q_group_count)
        for kv_window_idx in range(kv_windows_per_group)
        if not _causal_window_fully_future(cfg, q_group_idx, kv_window_idx)
    )
    state_restore_count = sum(
        state_groups_per_q_group
        for q_group_idx in range(q_group_count)
        for kv_window_idx in range(kv_windows_per_group)
        if (kv_window_idx != 0)
        and not _causal_window_fully_future(cfg, q_group_idx, kv_window_idx)
    )
    oacc_state_bits_per_state_group = (
        cfg.state_group_rows * cfg.head_dim * 16
    )
    oacc_cycles_per_state_group = _ceil_div(
        oacc_state_bits_per_state_group,
        cfg.oacc_sram_macro_count * cfg.oacc_sram_data_width,
    )
    counters = WindowedRtlCounters(
        q_group_count=q_group_count,
        kv_window_count=len(k_tile_requests) // cfg.kv_window_tiles,
        q_tile_visit_count=len(q_tile_requests),
        q_tile_req_count=len(q_tile_requests),
        q_tile_beat_count=len(q_tile_requests) * cfg.q_tile_beat_count,
        k_tile_req_count=len(k_tile_requests),
        k_tile_beat_count=len(k_tile_requests) * cfg.k_tile_beat_count,
        v_tile_req_count=len(v_tile_requests),
        v_tile_beat_count=len(v_tile_requests) * cfg.v_tile_beat_count,
        micro_tile_count=micro_tile_count,
        kv_tile_count=micro_tile_count,
        state_fill_count=state_fill_count,
        state_spill_count=state_fill_count,
        state_restore_count=state_restore_count,
        oacc_restore_cycle_count=state_restore_count * oacc_cycles_per_state_group,
        oacc_spill_cycle_count=state_fill_count * oacc_cycles_per_state_group,
        core_start_count=core_start_count,
        restore_start_count=sum(1 for event in core_starts if event.restore),
        qk_task_count=micro_tile_count * cfg.qk_tasks_per_micro_tile,
        pv_task_count=micro_tile_count * cfg.pv_tasks_per_micro_tile,
        oacc_task_count=micro_tile_count,
        skipped_future_kv_tiles=skipped_future_kv_tiles,
    )

    return WindowedRtlContract(
        config=cfg,
        counters=counters,
        q_tile_requests=q_tile_requests,
        k_tile_requests=k_tile_requests,
        v_tile_requests=v_tile_requests,
        core_starts=core_starts,
    )


def _causal_window_fully_future(
    cfg: WindowedRtlContractConfig, q_group_idx: int, kv_window_idx: int
) -> bool:
    if not cfg.causal:
        return False
    q_group_last_row = ((q_group_idx + 1) * cfg.q_group_rows) - 1
    kv_window_base_row = kv_window_idx * cfg.kv_window_tiles * cfg.kv_tile_rows
    return kv_window_base_row > q_group_last_row


def axi_read_metrics_for_windowed_contract(
    contract: WindowedRtlContract,
    layout: WindowedTopAxiLayoutConfig = WindowedTopAxiLayoutConfig(),
) -> WindowedTopAxiReadMetrics:
    cfg = contract.config
    q_axi_beats_per_tile = _ceil_div(cfg.q_tile_beat_count, 2)
    k_axi_beats_per_tile = _ceil_div(cfg.k_tile_beat_count, 2)
    v_axi_beats_per_tile = _ceil_div(cfg.v_tile_beat_count, 2)

    q_ar_per_tile = _ceil_div(q_axi_beats_per_tile, layout.max_burst_beats)
    k_ar_per_tile = _ceil_div(k_axi_beats_per_tile, layout.max_burst_beats)
    v_ar_per_tile = _ceil_div(v_axi_beats_per_tile, layout.max_burst_beats)

    ar_count = (
        len(contract.q_tile_requests) * q_ar_per_tile
        + len(contract.k_tile_requests) * k_ar_per_tile
        + len(contract.v_tile_requests) * v_ar_per_tile
    )
    r_beat_count = (
        len(contract.q_tile_requests) * q_axi_beats_per_tile
        + len(contract.k_tile_requests) * k_axi_beats_per_tile
        + len(contract.v_tile_requests) * v_axi_beats_per_tile
    )
    return WindowedTopAxiReadMetrics(
        ar_count=ar_count,
        r_beat_count=r_beat_count,
        rd_bytes=r_beat_count * layout.axi_beat_bytes,
    )


def axi_write_metrics_for_windowed_contract(
    contract: WindowedRtlContract,
    layout: WindowedTopAxiLayoutConfig = WindowedTopAxiLayoutConfig(),
) -> WindowedTopAxiWriteMetrics:
    cfg = contract.config
    q_group_count = cfg.seq_len // cfg.q_group_rows
    words_per_group = (cfg.q_group_rows * cfg.head_dim) // 2
    beats_per_group = _ceil_div(words_per_group, layout.axi_beat_bytes // 4)
    aw_per_group = _ceil_div(beats_per_group, layout.max_burst_beats)
    w_beat_count = q_group_count * beats_per_group
    return WindowedTopAxiWriteMetrics(
        aw_count=q_group_count * aw_per_group,
        w_beat_count=w_beat_count,
        wr_bytes=w_beat_count * layout.axi_beat_bytes,
    )


def dense_qk_direct_tile_beat64(
    kind: str, tile_idx: int, row_idx: int, chunk_idx: int
) -> int:
    base_col = chunk_idx * 4
    words = [
        _dense_qk_word(kind, tile_idx, row_idx, base_col + lane)
        for lane in range(4)
    ]
    return (
        (words[3] << 48)
        | (words[2] << 32)
        | (words[1] << 16)
        | words[0]
    )


def dense_qk_axi_tile_beat64(
    layout: WindowedTopAxiLayoutConfig,
    kind: str,
    tile_idx: int,
    row_idx: int,
    chunk_idx: int,
) -> int:
    if kind == "q":
        tile_base = layout.q_base + (tile_idx * layout.q_tile_bytes)
    elif kind == "k":
        tile_base = layout.k_base + (tile_idx * layout.kv_tile_bytes)
    elif kind == "v":
        tile_base = layout.v_base + (tile_idx * layout.kv_tile_bytes)
    else:
        raise ValueError(f"unknown dense-QK operand kind: {kind}")

    axi_beat_idx = (row_idx * 8) + (chunk_idx // 2)
    axi_addr = tile_base + (axi_beat_idx * layout.axi_beat_bytes)
    axi_beat = dense_qk_axi_beat128(layout, axi_addr)
    shift = 64 if (chunk_idx & 0x1) else 0
    return (axi_beat >> shift) & ((1 << 64) - 1)


def dense_qk_axi_beat128(layout: WindowedTopAxiLayoutConfig, addr: int) -> int:
    words = [dense_qk_axi_word32(layout, addr + byte_offset) for byte_offset in (0, 4, 8, 12)]
    return (words[3] << 96) | (words[2] << 64) | (words[1] << 32) | words[0]


def dense_qk_axi_word32(layout: WindowedTopAxiLayoutConfig, addr: int) -> int:
    if layout.q_base <= addr < layout.k_base:
        kind = "q"
        byte_offset = addr - layout.q_base
        tile_bytes = layout.q_tile_bytes
    elif layout.k_base <= addr < layout.v_base:
        kind = "k"
        byte_offset = addr - layout.k_base
        tile_bytes = layout.kv_tile_bytes
    elif layout.v_base <= addr < layout.o_base:
        kind = "v"
        byte_offset = addr - layout.v_base
        tile_bytes = layout.kv_tile_bytes
    else:
        raise ValueError(f"AXI read address outside Q/K/V regions: 0x{addr:016x}")

    tile_idx = byte_offset // tile_bytes
    word_in_tile = (byte_offset % tile_bytes) // 4
    row_idx = word_in_tile // 32
    col_pair_idx = word_in_tile % 32
    col_idx = col_pair_idx * 2
    lo_word = _dense_qk_word(kind, tile_idx, row_idx, col_idx)
    hi_word = _dense_qk_word(kind, tile_idx, row_idx, col_idx + 1)
    return (hi_word << 16) | lo_word


def dense_qk_o_write_word32(
    layout: WindowedTopAxiLayoutConfig,
    q_tile_idx: int,
    row_idx: int,
    col_pair_idx: int,
    o_word_fn,
) -> Tuple[int, int]:
    q_tiles_per_group = 16
    words_per_tile = 128
    group_idx = q_tile_idx // q_tiles_per_group
    tile_in_group_idx = q_tile_idx % q_tiles_per_group
    word_in_tile = (row_idx * 32) + col_pair_idx
    group_word_idx = (tile_in_group_idx * words_per_tile) + word_in_tile
    addr = layout.o_base + (group_idx * 8192) + (group_word_idx * 4)
    col_idx = col_pair_idx * 2
    lo_word = o_word_fn(q_tile_idx, row_idx, col_idx)
    hi_word = o_word_fn(q_tile_idx, row_idx, col_idx + 1)
    return addr, (hi_word << 16) | lo_word


def count_k_layout_roundtrip_errors(cfg: WindowedRtlContractConfig) -> int:
    cfg.validate()
    error_count = 0
    window: Dict[Tuple[int, int, int], Tuple[int, int, int, int]] = {}
    for slot_idx in range(cfg.kv_window_tiles):
        for row_idx in range(cfg.kv_tile_rows):
            for chunk_idx in range(cfg.head_dim // 4):
                for pair_in_chunk in range(2):
                    bank, addr, row_lane = k_sram_write_address(
                        slot_idx, row_idx, chunk_idx, pair_in_chunk
                    )
                    window[(bank, addr, row_lane)] = (
                        slot_idx,
                        row_idx,
                        chunk_idx,
                        pair_in_chunk,
                    )

    for slot_idx in range(cfg.kv_window_tiles):
        for pair_idx in range(cfg.head_dim // 2):
            chunk_idx = pair_idx >> 1
            pair_in_chunk = pair_idx & 1
            for row_idx in range(cfg.kv_tile_rows):
                bank, addr, row_lane = k_sram_read_address(slot_idx, row_idx, pair_idx)
                stored = window.get((bank, addr, row_lane))
                if stored != (slot_idx, row_idx, chunk_idx, pair_in_chunk):
                    error_count += 1
    return error_count


def count_v_layout_roundtrip_errors(
    cfg: WindowedRtlContractConfig, *, v_write_addr_uses_slot: bool = True
) -> int:
    cfg.validate()
    error_count = 0
    window: Dict[Tuple[int, int], Tuple[int, int, int]] = {}
    for slot_idx in range(cfg.kv_window_tiles):
        for row_idx in range(cfg.kv_tile_rows):
            for chunk_idx in range(cfg.head_dim // 4):
                bank, addr = v_sram_write_address(
                    slot_idx,
                    row_idx,
                    chunk_idx,
                    uses_slot=v_write_addr_uses_slot,
                )
                window[(bank, addr)] = (slot_idx, row_idx, chunk_idx)

    for slot_idx in range(cfg.kv_window_tiles):
        for wave_idx in range(4):
            for pair_idx in range(8):
                for chunk_low_idx in range(4):
                    chunk_idx = (wave_idx << 2) | chunk_low_idx
                    low_row = pair_idx << 1
                    high_row = low_row + 1
                    low_bank, low_addr = v_sram_read_address(
                        slot_idx, wave_idx, pair_idx, chunk_low_idx, high=False
                    )
                    high_bank, high_addr = v_sram_read_address(
                        slot_idx, wave_idx, pair_idx, chunk_low_idx, high=True
                    )
                    if window.get((low_bank, low_addr)) != (slot_idx, low_row, chunk_idx):
                        error_count += 1
                    if window.get((high_bank, high_addr)) != (slot_idx, high_row, chunk_idx):
                        error_count += 1
    return error_count


def k_sram_write_address(
    slot_idx: int, row_idx: int, chunk_idx: int, pair_in_chunk: int
) -> Tuple[int, int, int]:
    bank = (row_idx >> 1) & 0x7
    addr = ((slot_idx & 0x3) << 5) | ((chunk_idx & 0xF) << 1) | (pair_in_chunk & 0x1)
    row_lane = row_idx & 0x1
    return bank, addr, row_lane


def _dense_qk_word(kind: str, tile_idx: int, row_idx: int, col_idx: int) -> int:
    if kind == "q":
        row_tile_sum = ((row_idx & 0x3) + (tile_idx & 0x3)) & 0x3
        return 1 + row_tile_sum + (col_idx & 0x3)
    if kind == "k":
        row_tile_sum = ((row_idx & 0x3) + (tile_idx & 0x3)) & 0x3
        return 1 + row_tile_sum + (col_idx & 0x3)
    if kind == "v":
        return 0x0010 + ((tile_idx & 0xF) << 4) + (row_idx & 0xF) + (col_idx & 0x3F)
    raise ValueError(f"unknown dense-QK operand kind: {kind}")


def _ceil_div(numerator: int, denominator: int) -> int:
    return (numerator + denominator - 1) // denominator


def _micro_tiles_for_event(
    cfg: WindowedRtlContractConfig, event: CoreStartEvent
) -> int:
    raw_end_idx = event.kv_base_idx + cfg.micro_tiles_per_core_start
    if not cfg.causal:
        return cfg.micro_tiles_per_core_start

    q_tile_last_row_idx = (event.q_tile_idx * cfg.q_tile_rows) + cfg.q_tile_rows - 1
    causal_end_idx = (q_tile_last_row_idx // cfg.kv_tile_rows) + 1
    effective_end_idx = min(raw_end_idx, causal_end_idx)
    return max(0, effective_end_idx - event.kv_base_idx)


def k_sram_read_address(slot_idx: int, row_idx: int, pair_idx: int) -> Tuple[int, int, int]:
    bank = (row_idx >> 1) & 0x7
    addr = ((slot_idx & 0x3) << 5) | (((pair_idx >> 1) & 0xF) << 1) | (pair_idx & 0x1)
    row_lane = row_idx & 0x1
    return bank, addr, row_lane


def v_sram_write_address(
    slot_idx: int, row_idx: int, chunk_idx: int, *, uses_slot: bool = True
) -> Tuple[int, int]:
    slot_field = slot_idx & 0x3 if uses_slot else 0
    bank = ((row_idx & 0x1) << 2) | (chunk_idx & 0x3)
    addr = (
        (slot_field << 5)
        | (((row_idx >> 3) & 0x1) << 4)
        | (((row_idx >> 1) & 0x3) << 2)
        | ((chunk_idx >> 2) & 0x3)
    )
    return bank, addr


def v_sram_read_address(
    slot_idx: int, wave_idx: int, pair_idx: int, chunk_low_idx: int, *, high: bool
) -> Tuple[int, int]:
    bank = (4 if high else 0) + (chunk_low_idx & 0x3)
    addr = (
        ((slot_idx & 0x3) << 5)
        | (((pair_idx >> 2) & 0x1) << 4)
        | ((pair_idx & 0x3) << 2)
        | (wave_idx & 0x3)
    )
    return bank, addr
