#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)"
RTL_DIR="${REPO_ROOT}/rtl"
TB_DIR="${REPO_ROOT}/tb"
BUILD_DIR="${SCRIPT_DIR}/build"

TOP_MODULE="${TOP_MODULE:-tb_gemm}"
SAFE_TOP="${TOP_MODULE//[^[:alnum:]_]/_}"
WAVE_OUT="${WAVE_OUT:-${SCRIPT_DIR}/${SAFE_TOP}.vcd}"
VVP_OUT="${VVP_OUT:-${BUILD_DIR}/${SAFE_TOP}.vvp}"
MODE="${1:-sim}"

FILELIST="${BUILD_DIR}/${SAFE_TOP}.f"
WRAPPER="${BUILD_DIR}/__iverilog_dump_wrapper_${SAFE_TOP}.v"
WRAPPER_TOP="__iverilog_dump_wrapper_${SAFE_TOP}"

usage() {
    cat <<'EOF'
Usage:
  ./run_sim.sh compile
  ./run_sim.sh sim

Environment overrides:
  TOP_MODULE   simulation top module (default: tb_gemm)
  WAVE_OUT     output VCD path
  VVP_OUT      compiled vvp path
EOF
}

ensure_layout() {
    if [[ ! -d "${RTL_DIR}" ]]; then
        echo "Error: RTL directory not found: ${RTL_DIR}" >&2
        exit 1
    fi

    if [[ ! -d "${TB_DIR}" ]]; then
        echo "Error: testbench directory not found: ${TB_DIR}" >&2
        exit 1
    fi

    mkdir -p "${BUILD_DIR}"
    mkdir -p "$(dirname -- "${WAVE_OUT}")"
    mkdir -p "$(dirname -- "${VVP_OUT}")"
}

generate_filelist() {
    find "${RTL_DIR}" "${TB_DIR}" -type f -name '*.v' | sort > "${FILELIST}"

    if [[ ! -s "${FILELIST}" ]]; then
        echo "Error: no Verilog sources found under ${RTL_DIR} or ${TB_DIR}" >&2
        exit 1
    fi
}

generate_wrapper() {
    cat > "${WRAPPER}" <<EOF
\`timescale 1ns/1ps

module ${WRAPPER_TOP};
    ${TOP_MODULE} dut();

    initial begin
        \$dumpfile("${WAVE_OUT}");
        \$dumpvars(0, dut);
    end
endmodule
EOF
}

compile_design() {
    echo "Compiling ${TOP_MODULE} with iverilog..."
    # The current RTL/testbenches are written in Verilog-2001.
    # Using a newer SystemVerilog mode makes identifiers like "expect"
    # parse as reserved keywords in existing benches.
    iverilog -g2001 -Wall -s "${WRAPPER_TOP}" -o "${VVP_OUT}" -c "${FILELIST}" "${WRAPPER}"
    echo "Compile output: ${VVP_OUT}"
}

run_sim() {
    echo "Running ${TOP_MODULE} with vvp..."
    vvp "${VVP_OUT}"
    echo "Waveform saved to ${WAVE_OUT}"
}

main() {
    case "${MODE}" in
        compile|sim)
            ;;
        help|-h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown mode '${MODE}'" >&2
            usage >&2
            exit 1
            ;;
    esac

    ensure_layout
    generate_filelist
    generate_wrapper
    compile_design

    if [[ "${MODE}" == "sim" ]]; then
        run_sim
    fi
}

main "$@"
