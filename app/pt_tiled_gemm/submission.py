from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from typing import Deque, Optional

from . import is_wrapper_target, normalize_app_target


SUBMISSION_MODE_LEGACY = "legacy"
SUBMISSION_MODE_SHADOW_DELTA = "shadow_delta"
SUBMISSION_MODE_COMPACT = "compact"
SUPPORTED_SUBMISSION_MODES = (
	SUBMISSION_MODE_LEGACY,
	SUBMISSION_MODE_SHADOW_DELTA,
	SUBMISSION_MODE_COMPACT,
)


def normalize_submission_mode(mode: str | None) -> str:
	if mode is None:
		return SUBMISSION_MODE_LEGACY
	name = mode.strip().lower()
	alias_map = {
		"legacy": SUBMISSION_MODE_LEGACY,
		"full": SUBMISSION_MODE_LEGACY,
		"shadow_delta": SUBMISSION_MODE_SHADOW_DELTA,
		"shadow-delta": SUBMISSION_MODE_SHADOW_DELTA,
		"delta": SUBMISSION_MODE_SHADOW_DELTA,
		"compact": SUBMISSION_MODE_COMPACT,
	}
	try:
		return alias_map[name]
	except KeyError as exc:
		raise ValueError(f"unsupported submission mode {mode!r}") from exc


@dataclass
class SubmissionStats:
	submission_mode: str
	command_count: int = 0
	axil_writes_total: int = 0
	axil_reads_total: int = 0
	descriptor_push_count: int = 0

	@property
	def axil_writes_per_command(self) -> float:
		return 0.0 if self.command_count == 0 else (self.axil_writes_total / self.command_count)


class CtrlIdPool:
	def __init__(self, ctrl_id_base: int, pool_size: int):
		if pool_size <= 0:
			raise ValueError(f"pool_size must be > 0, got {pool_size}")
		self.ctrl_id_base = ctrl_id_base & 0xFFFF_FFFF
		self.pool_size = pool_size
		self._available: Deque[int] = deque(
			[(self.ctrl_id_base + idx) & 0xFFFF_FFFF for idx in range(pool_size)]
		)
		self._in_use: set[int] = set()

	def acquire(self) -> int:
		if not self._available:
			raise RuntimeError("ctrl_id pool exhausted")
		ctrl_id = self._available.popleft()
		self._in_use.add(ctrl_id)
		return ctrl_id

	def release(self, ctrl_id: int) -> None:
		value = ctrl_id & 0xFFFF_FFFF
		if value not in self._in_use:
			raise RuntimeError(f"ctrl_id 0x{value:08x} is not currently in use")
		self._in_use.remove(value)
		self._available.append(value)


class CommandSubmitter:
	def __init__(
		self,
		env,
		*,
		target: str,
		submission_mode: str,
		ctrl_id_base: int,
		ctrl_id_pool_size: int,
	):
		self.env = env
		self.target = normalize_app_target(target)
		self.submission_mode = normalize_submission_mode(submission_mode)
		self.stats = SubmissionStats(submission_mode=self.submission_mode)
		self._ctrl_id_pool = None
		if is_wrapper_target(self.target):
			self._ctrl_id_pool = CtrlIdPool(ctrl_id_base, ctrl_id_pool_size)

	def acquire_ctrl_id(self, fallback_ctrl_id: Optional[int] = None) -> int:
		if self._ctrl_id_pool is None:
			if fallback_ctrl_id is None:
				raise ValueError("fallback_ctrl_id is required for non-wrapper targets")
			return fallback_ctrl_id & 0xFFFF_FFFF
		return self._ctrl_id_pool.acquire()

	def release_ctrl_id(self, ctrl_id: int) -> None:
		if self._ctrl_id_pool is None:
			return
		self._ctrl_id_pool.release(ctrl_id)

	async def send_ctrl(self, inst: int, ctrl_id: int, timeout_cycles: int = 4000):
		if is_wrapper_target(self.target):
			trace = await self.env.send_ctrl_timed(
				inst,
				ctrl_id,
				timeout_cycles=timeout_cycles,
				mode=self.submission_mode,
			)
			self.stats.command_count += 1
			self.stats.axil_writes_total += trace.axil_writes
			self.stats.axil_reads_total += trace.axil_reads
			self.stats.descriptor_push_count += 1
			return trace
		trace = await self.env.send_ctrl_timed(inst, ctrl_id, timeout_cycles=timeout_cycles)
		self.stats.command_count += 1
		return trace
