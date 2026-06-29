proc getenv_default {name default_value} {
    global env
    if {[info exists env($name)] && $env($name) ne ""} {
        return $env($name)
    }
    return $default_value
}

proc require_file {path label} {
    if {![file exists $path]} {
        puts "CODEX_ERROR missing $label: $path"
        exit 2
    }
}

proc compile_lib_to_db {lib_path lib_name db_output_dir} {
    require_file $lib_path "Liberty"
    file mkdir $db_output_dir
    puts "CODEX_LC_READ $lib_path"
    read_lib $lib_path
    set db_path [file join $db_output_dir ${lib_name}.db]
    puts "CODEX_LC_WRITE $db_path"
    write_lib $lib_name -format db -output $db_path
}

set output_dir [getenv_default FA_SRAM_DB_OUTPUT_DIR [file join [pwd] remote_reports libs]]
set sram256x64_lib [getenv_default FA_SRAM256X64_LIB /mnt/hgfs/TSMC28/Memory/temn28hpcphssrammacros_170a/AN61001_20180125/TSMCHOME/sram/Front_End/timing_power_noise/NLDM/temn28hpcphssrammacros_110a/tem5n28hpcplvta256x64m4swso_110a/tem5n28hpcplvta256x64m4swso_110a_ffg0p99v0c.lib]
set sram256x32_lib [getenv_default FA_SRAM256X32_LIB /mnt/hgfs/TSMC28/Memory/temn28hpcphssrammacros_170a/AN61001_20180125/TSMCHOME/sram/Front_End/timing_power_noise/NLDM/temn28hpcphssrammacros_110a/tem5n28hpcplvta256x32m4swso_110a/tem5n28hpcplvta256x32m4swso_110a_ffg0p99v0c.lib]
set sram256x64_name [getenv_default FA_SRAM256X64_LIB_NAME tem5n28hpcplvta256x64m4swso_110a_ffg0p99v0c]
set sram256x32_name [getenv_default FA_SRAM256X32_LIB_NAME tem5n28hpcplvta256x32m4swso_110a_ffg0p99v0c]

compile_lib_to_db $sram256x64_lib $sram256x64_name $output_dir
compile_lib_to_db $sram256x32_lib $sram256x32_name $output_dir

puts "CODEX_LC_DONE output_dir=$output_dir"
exit
