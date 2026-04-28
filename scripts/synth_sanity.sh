#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
RTL_DIR="${REPO_ROOT}/rtl"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/flash_atten_synth_sanity.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

shopt -s nullglob

ROOT_SOURCES=("${RTL_DIR}"/*.v)

log() {
	printf '[synth_sanity] %s\n' "$*"
}

scan_forbidden_constructs() {
	log "Scanning rtl/ for synth-visible forbidden constructs"

	local findings=0
	local file
	for file in "${RTL_DIR}"/*.v "${RTL_DIR}"/*.vh; do
		[[ -f "${file}" ]] || continue
		if ! awk -v file="${file}" '
			function check_line(code, lineno) {
				if (code ~ /(^|[^[:alnum:]_$])initial([^[:alnum:]_]|$)/ ||
				    code ~ /\$fatal\b/ ||
				    code ~ /\$display\b/ ||
				    code ~ /\$finish\b/ ||
				    code ~ /\$stop\b/) {
					print file ":" lineno ":" code
					found = 1
				}
			}
			{
				code = $0
				sub(/\/\/.*/, "", code)

				if (code ~ /synthesis[[:space:]]+translate_off/) {
					synth_off = 1
				}
				if (code ~ /^[[:space:]]*`ifndef[[:space:]]+SYNTHESIS([[:space:]]|$)/) {
					synth_guard++
				}

				if (!synth_off && synth_guard == 0) {
					check_line(code, NR)
				}

				if (synth_guard > 0 && code ~ /^[[:space:]]*`endif([[:space:]]|$)/) {
					synth_guard--
				}
				if (code ~ /synthesis[[:space:]]+translate_on/) {
					synth_off = 0
				}
			}
			END {
				exit found ? 1 : 0
			}
		' "${file}"; then
			findings=1
		fi
	done

	if [[ "${findings}" -ne 0 ]]; then
		echo "Forbidden synth-visible constructs found outside synthesis guards" >&2
		return 1
	fi
}

lint_verilator() {
	local top="$1"
	shift
	local log_file="${TMP_DIR}/${top}.verilator.log"
	log "Verilator lint: ${top}"
	verilator --lint-only -Wall -Wno-fatal \
		-Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-EOFNEWLINE \
		-Wno-PINCONNECTEMPTY -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
		-Wno-WIDTHCONCAT -Wno-BLKSEQ -Wno-SYNCASYNCNET \
		-DSYNTHESIS --top-module "${top}" "$@" > "${log_file}" 2>&1
	if grep -Eq '^(%Warning|%Error)' "${log_file}"; then
		cat "${log_file}" >&2
		echo "Unexpected Verilator diagnostics for top ${top}" >&2
		return 1
	fi
}

main() {
	if [[ "${#ROOT_SOURCES[@]}" -eq 0 ]]; then
		echo "No root RTL sources found under ${RTL_DIR}" >&2
		exit 1
	fi
	scan_forbidden_constructs

	lint_verilator "FA_TOP_BASELINE" -I"${RTL_DIR}" "${ROOT_SOURCES[@]}"
	lint_verilator "csr_array" -I"${RTL_DIR}" "${ROOT_SOURCES[@]}"
	lint_verilator "GEMM_V3" -I"${RTL_DIR}" "${ROOT_SOURCES[@]}"
	lint_verilator "GEMU_V3" -I"${RTL_DIR}" "${ROOT_SOURCES[@]}"

	log "All synthesis sanity checks passed"
}

main "$@"
