from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Tuple


@dataclass(frozen=True)
class WindowedRtlContractConfig:
    seq_len: int = 256
    head_dim: int = 64
    q_group_rows: int = 64
    q_tile_rows: int = 4
    kv_tile_rows: int = 16
    kv_window_tiles: int = 4
    q_tile_beat_count: int = 64
    k_tile_beat_count: int = 256
    v_tile_beat_count: int = 256
    micro_tiles_per_core_start: int = 4
    qk_tasks_per_micro_tile: int = 128
    pv_tasks_per_micro_tile: int = 128

    def validate(self) -> None:
        positive_fields = {
            "seq_len": self.seq_len,
            "head_dim": self.head_dim,
            "q_group_rows": self.q_group_rows,
            "q_tile_rows": self.q_tile_rows,
            "kv_tile_rows": self.kv_tile_rows,
            "kv_window_tiles": self.kv_window_tiles,
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
        if self.seq_len % self.kv_tile_rows != 0:
            raise ValueError("seq_len must be divisible by kv_tile_rows")
        if (self.seq_len // self.kv_tile_rows) % self.kv_window_tiles != 0:
            raise ValueError("KV tile count must be divisible by kv_window_tiles")


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
    core_start_count: int
    restore_start_count: int
    qk_task_count: int
    pv_task_count: int
    oacc_task_count: int


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
    kv_tile_count = cfg.seq_len // cfg.kv_tile_rows
    kv_windows_per_group = kv_tile_count // cfg.kv_window_tiles

    q_tile_requests: List[int] = []
    k_tile_requests: List[int] = []
    v_tile_requests: List[int] = []
    core_starts: List[CoreStartEvent] = []

    for q_group_idx in range(q_group_count):
        for kv_window_idx in range(kv_windows_per_group):
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
    micro_tile_count = core_start_count * cfg.micro_tiles_per_core_start
    counters = WindowedRtlCounters(
        q_group_count=q_group_count,
        kv_window_count=q_group_count * kv_windows_per_group,
        q_tile_visit_count=len(q_tile_requests),
        q_tile_req_count=len(q_tile_requests),
        q_tile_beat_count=len(q_tile_requests) * cfg.q_tile_beat_count,
        k_tile_req_count=len(k_tile_requests),
        k_tile_beat_count=len(k_tile_requests) * cfg.k_tile_beat_count,
        v_tile_req_count=len(v_tile_requests),
        v_tile_beat_count=len(v_tile_requests) * cfg.v_tile_beat_count,
        micro_tile_count=micro_tile_count,
        kv_tile_count=micro_tile_count,
        state_fill_count=len(q_tile_requests),
        state_spill_count=len(q_tile_requests),
        core_start_count=core_start_count,
        restore_start_count=sum(1 for event in core_starts if event.restore),
        qk_task_count=micro_tile_count * cfg.qk_tasks_per_micro_tile,
        pv_task_count=micro_tile_count * cfg.pv_tasks_per_micro_tile,
        oacc_task_count=micro_tile_count,
    )

    return WindowedRtlContract(
        config=cfg,
        counters=counters,
        q_tile_requests=q_tile_requests,
        k_tile_requests=k_tile_requests,
        v_tile_requests=v_tile_requests,
        core_starts=core_starts,
    )


def count_k_layout_roundtrip_errors(cfg: WindowedRtlContractConfig) -> int:
    cfg.validate()
    error_count = 0
    window: Dict[Tuple[int, int], Tuple[int, int, int]] = {}
    for slot_idx in range(cfg.kv_window_tiles):
        for row_idx in range(cfg.kv_tile_rows):
            for chunk_idx in range(cfg.head_dim // 4):
                bank, addr = k_sram_write_address(slot_idx, row_idx, chunk_idx)
                window[(bank, addr)] = (slot_idx, row_idx, chunk_idx)

    for slot_idx in range(cfg.kv_window_tiles):
        for pair_idx in range(cfg.head_dim // 2):
            chunk_idx = pair_idx >> 1
            for row_idx in range(cfg.kv_tile_rows):
                bank, addr = k_sram_read_address(slot_idx, row_idx, pair_idx)
                stored = window.get((bank, addr))
                if stored != (slot_idx, row_idx, chunk_idx):
                    error_count += 1
    return error_count


def count_v_layout_roundtrip_errors(
    cfg: WindowedRtlContractConfig, *, v_write_bank_uses_slot_high: bool = True
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
                    uses_slot_high=v_write_bank_uses_slot_high,
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


def k_sram_write_address(slot_idx: int, row_idx: int, chunk_idx: int) -> Tuple[int, int]:
    bank = row_idx & 0xF
    addr = ((slot_idx & 0x3) << 4) | (chunk_idx & 0xF)
    return bank, addr


def k_sram_read_address(slot_idx: int, row_idx: int, pair_idx: int) -> Tuple[int, int]:
    bank = row_idx & 0xF
    addr = ((slot_idx & 0x3) << 4) | ((pair_idx >> 1) & 0xF)
    return bank, addr


def v_sram_write_address(
    slot_idx: int, row_idx: int, chunk_idx: int, *, uses_slot_high: bool = True
) -> Tuple[int, int]:
    slot_high = (slot_idx >> 1) & 0x1 if uses_slot_high else 0
    bank = (slot_high << 3) | ((row_idx & 0x1) << 2) | (chunk_idx & 0x3)
    row_field = ((slot_idx & 0x3) << 1) | ((row_idx >> 3) & 0x1)
    chunk_field = (((row_idx >> 1) & 0x3) << 2) | ((chunk_idx >> 2) & 0x3)
    addr = (row_field << 4) | chunk_field
    return bank, addr


def v_sram_read_address(
    slot_idx: int, wave_idx: int, pair_idx: int, chunk_low_idx: int, *, high: bool
) -> Tuple[int, int]:
    bank_base = 8 if ((slot_idx >> 1) & 0x1) else 0
    bank = bank_base + (4 if high else 0) + (chunk_low_idx & 0x3)
    row_field = ((slot_idx & 0x3) << 1) | ((pair_idx >> 2) & 0x1)
    chunk_field = ((pair_idx & 0x3) << 2) | (wave_idx & 0x3)
    addr = (row_field << 4) | chunk_field
    return bank, addr
