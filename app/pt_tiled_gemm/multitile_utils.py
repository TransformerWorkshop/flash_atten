from __future__ import annotations

from dataclasses import dataclass
from itertools import accumulate, product


@dataclass(frozen=True)
class MultitileCommand:
	m_tile_off: int
	n_tile_off: int
	k_tile_off: int
	m_tiles: int
	n_tiles: int
	k_tiles: int


def command_fits(
	*,
	m_tiles: int,
	n_tiles: int,
	k_tiles: int,
	max_encoded_elems: int,
	x_dim: int,
	y_dim: int,
	pack_lanes: int = 1,
) -> bool:
	k_words_per_tile = x_dim if pack_lanes <= 1 else (x_dim // pack_lanes)
	a_elems = x_dim * k_words_per_tile * m_tiles * k_tiles
	b_elems = y_dim * k_words_per_tile * k_tiles * n_tiles
	return max(a_elems, b_elems) <= max_encoded_elems


def enumerate_partitions(total_tiles: int, valid_tile_counts: tuple[int, ...]) -> list[tuple[int, ...]]:
	ordered = tuple(sorted(valid_tile_counts, reverse=True))
	results: list[tuple[int, ...]] = []

	def _walk(remaining: int, prefix: tuple[int, ...]) -> None:
		if remaining == 0:
			results.append(prefix)
			return
		for tile_count in ordered:
			if tile_count <= remaining:
				_walk(remaining - tile_count, prefix + (tile_count,))

	_walk(total_tiles, ())
	results.sort(key=lambda parts: (len(parts), tuple(-item for item in parts)))
	return results


def choose_partition_plan(
	*,
	m_tiles: int,
	n_tiles: int,
	k_tiles: int,
	valid_tile_counts: tuple[int, ...],
	max_encoded_elems: int,
	x_dim: int,
	y_dim: int,
	pack_lanes: int = 1,
) -> tuple[tuple[int, ...], tuple[int, ...], tuple[int, ...]]:
	m_partitions = enumerate_partitions(m_tiles, valid_tile_counts)
	n_partitions = enumerate_partitions(n_tiles, valid_tile_counts)
	k_partitions = enumerate_partitions(k_tiles, valid_tile_counts)
	best: tuple[tuple[int, ...], tuple[int, ...], tuple[int, ...]] | None = None
	best_score: tuple[int, int, int, int, tuple[int, ...], tuple[int, ...], tuple[int, ...]] | None = None
	for m_parts, n_parts, k_parts in product(m_partitions, n_partitions, k_partitions):
		if not all(
			command_fits(
				m_tiles=m_part,
				n_tiles=n_part,
				k_tiles=k_part,
				max_encoded_elems=max_encoded_elems,
				x_dim=x_dim,
				y_dim=y_dim,
				pack_lanes=pack_lanes,
			)
			for m_part, n_part, k_part in product(m_parts, n_parts, k_parts)
		):
			continue
		score = (
			len(m_parts) * len(n_parts) * len(k_parts),
			len(k_parts),
			len(m_parts) + len(n_parts),
			len(m_parts),
			tuple(-item for item in m_parts),
			tuple(-item for item in n_parts),
			tuple(-item for item in k_parts),
		)
		if best_score is None or score < best_score:
			best = (m_parts, n_parts, k_parts)
			best_score = score
	if best is None:
		raise ValueError(f"no feasible multitile partition for m={m_tiles}, n={n_tiles}, k={k_tiles}")
	return best


def build_command_schedule(
	*,
	m_parts: tuple[int, ...],
	n_parts: tuple[int, ...],
	k_parts: tuple[int, ...],
) -> list[MultitileCommand]:
	m_offsets = [0, *accumulate(m_parts[:-1])]
	n_offsets = [0, *accumulate(n_parts[:-1])]
	k_offsets = [0, *accumulate(k_parts[:-1])]
	return [
		MultitileCommand(
			m_tile_off=m_off,
			n_tile_off=n_off,
			k_tile_off=k_off,
			m_tiles=m_part,
			n_tiles=n_part,
			k_tiles=k_part,
		)
		for m_off, m_part in zip(m_offsets, m_parts)
		for n_off, n_part in zip(n_offsets, n_parts)
		for k_off, k_part in zip(k_offsets, k_parts)
	]
