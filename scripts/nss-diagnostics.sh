#!/bin/sh
# Read-only NSS/ECM diagnostic snapshot for OpenWrt.
# This script prints to stdout only. It never calls uci set/commit, mounts a
# filesystem, loads/unloads a module, or writes a temporary/persistent file.
set -u

section() {
    printf '\n===== %s =====\n' "$1"
}

run() {
    printf '\n$'
    for arg in "$@"; do
        printf ' %s' "$arg"
    done
    printf '\n'
    "$@" 2>&1 || printf '[command unavailable or returned non-zero: %s]\n' "$1"
}

read_path() {
    path="$1"
    if [ -r "$path" ]; then
        printf '\n--- %s ---\n' "$path"
        cat "$path" 2>&1 || true
    else
        printf '\n--- %s: unavailable ---\n' "$path"
    fi
}

uci_value() {
    key="$1"
    if command -v uci >/dev/null 2>&1; then
        value="$(uci -q get "$key" 2>/dev/null || true)"
        if [ -n "$value" ]; then
            printf '%s=%s\n' "$key" "$value"
        else
            printf '%s=<unset or unavailable>\n' "$key"
        fi
    else
        printf '%s=<uci unavailable>\n' "$key"
    fi
}

dump_module_parameters() {
    found=0
    for module_dir in /sys/module/*; do
        [ -d "$module_dir" ] || continue
        module="${module_dir##*/}"
        case "$module" in
            *nss*|*NSS*|*ecm*|*ECM*) ;;
            *) continue ;;
        esac
        found=1
        printf '\n--- module %s ---\n' "$module"
        if [ -d "$module_dir/parameters" ]; then
            for parameter in "$module_dir"/parameters/*; do
                [ -r "$parameter" ] || continue
                printf '%s=' "${parameter##*/}"
                cat "$parameter" 2>/dev/null || printf '<unreadable>\n'
            done
        else
            printf '<no readable parameters>\n'
        fi
    done
    [ "$found" -eq 1 ] || printf '<no matching loaded modules>\n'
}

section 'identity and uptime'
run date -u
run uname -a
read_path /proc/uptime
read_path /proc/cmdline
read_path /tmp/sysinfo/model
read_path /etc/openwrt_release

section 'NSS firmware evidence'
if [ -d /lib/firmware ]; then
    printf '%s\n' 'Matching files below /lib/firmware:'
    find /lib/firmware -type f 2>/dev/null | grep -Ei '/[^/]*(nss|qca.*fw|ipq.*fw)[^/]*$' || \
        printf '<no matching firmware filenames>\n'
else
    printf '<firmware directory unavailable>\n'
fi
if command -v dmesg >/dev/null 2>&1; then
    printf '\nNSS/ECM/firmware-related kernel messages:\n'
    dmesg 2>/dev/null | grep -Ei '(^|[^[:alnum:]_])(nss|ecm|ppe|edma|firmware)([^[:alnum:]_]|$)' || \
        printf '<no matching kernel messages or dmesg unavailable>\n'
fi

section 'installed NSS, ECM and firmware packages'
if command -v apk >/dev/null 2>&1; then
    apk info 2>/dev/null | grep -Ei '(nss|ecm|firmware)' || \
        printf '<no matching apk packages>\n'
elif command -v opkg >/dev/null 2>&1; then
    opkg list-installed 2>/dev/null | grep -Ei '(nss|ecm|firmware)' || \
        printf '<no matching opkg packages>\n'
else
    printf '<apk/opkg unavailable>\n'
fi

section 'loaded NSS, ECM, PPE, EDMA and Wi-Fi modules'
if [ -r /proc/modules ]; then
    grep -Ei '(^|_)(qca_?nss|nss|ecm|ppe|edma|ath11k|wifi)' /proc/modules || \
        printf '<no matching entries in /proc/modules>\n'
else
    printf '<proc modules unavailable>\n'
fi
printf '\nNSS/ECM module parameters:\n'
dump_module_parameters

section 'ECM and NSS debug status'
for debug_dir in \
    /sys/kernel/debug/ecm \
    /sys/kernel/debug/qca-nss-drv \
    /sys/kernel/debug/qca_nss_drv \
    /sys/kernel/debug/qca-nss-ecm; do
    if [ -d "$debug_dir" ]; then
        printf '\n--- listing %s (debugfs was already mounted) ---\n' "$debug_dir"
        find "$debug_dir" -maxdepth 3 -print 2>/dev/null | sort || true
    else
        printf '\n--- %s: unavailable ---\n' "$debug_dir"
    fi
done
for status_file in \
    /sys/kernel/debug/ecm/ecm_db/connection_count \
    /sys/kernel/debug/ecm/ecm_db/connection_count_by_protocol \
    /sys/kernel/debug/ecm/ecm_classifier_default/enabled \
    /sys/kernel/debug/ecm/ecm_front_end_ipv4/accelerated_count \
    /sys/kernel/debug/ecm/ecm_front_end_ipv6/accelerated_count; do
    [ -e "$status_file" ] && read_path "$status_file"
done

section 'CPU, scheduler and thermal state'
read_path /sys/devices/system/cpu/online
read_path /proc/loadavg
read_path /proc/cpuinfo
read_path /proc/stat
read_path /proc/softirqs
for cpu_state in \
    /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq \
    /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -r "$cpu_state" ] || continue
    printf '%s=' "$cpu_state"
    cat "$cpu_state" 2>/dev/null || true
done
for thermal_zone in /sys/class/thermal/thermal_zone*; do
    [ -d "$thermal_zone" ] || continue
    for thermal_value in "$thermal_zone/type" "$thermal_zone/temp"; do
        [ -r "$thermal_value" ] || continue
        printf '%s=' "$thermal_value"
        cat "$thermal_value" 2>/dev/null || true
    done
done

section 'interrupts and affinity'
read_path /proc/interrupts
read_path /proc/irq/default_smp_affinity
if [ -r /proc/interrupts ]; then
    printf '\nSelected NSS/ECM/PPE/EDMA/Ethernet/Wi-Fi IRQ affinities:\n'
    sed -n -E '/nss|ecm|ppe|edma|ethernet|eth|ath11k|wifi|wlan/Ip' /proc/interrupts |
    while IFS= read -r irq_line; do
        irq="${irq_line%%:*}"
        irq="$(printf '%s' "$irq" | tr -d '[:space:]')"
        [ -n "$irq" ] || continue
        printf '%s\n' "$irq_line"
        if [ -r "/proc/irq/$irq/smp_affinity_list" ]; then
            printf '  smp_affinity_list='
            cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true
        elif [ -r "/proc/irq/$irq/smp_affinity" ]; then
            printf '  smp_affinity='
            cat "/proc/irq/$irq/smp_affinity" 2>/dev/null || true
        fi
    done
fi

section 'packet steering and queue CPU masks'
uci_value network.globals.packet_steering
for mask in \
    /sys/class/net/*/queues/rx-*/rps_cpus \
    /sys/class/net/*/queues/tx-*/xps_cpus; do
    [ -r "$mask" ] || continue
    printf '%s=' "$mask"
    cat "$mask" 2>/dev/null || true
done

section 'firewall flow-offload state'
uci_value 'firewall.@defaults[0].flow_offloading'
uci_value 'firewall.@defaults[0].flow_offloading_hw'
if command -v nft >/dev/null 2>&1; then
    printf '\nRuntime nftables flowtable/offload rules:\n'
    nft list ruleset 2>/dev/null | grep -Ei 'flowtable|flow offload|flags[[:space:]]+offload' || \
        printf '<no matching nftables rules or ruleset unavailable>\n'
else
    printf '<nft unavailable>\n'
fi

section 'bridge and VLAN filtering state'
if command -v ip >/dev/null 2>&1; then
    run ip -details link show type bridge
    run ip -details link show
fi
if command -v bridge >/dev/null 2>&1; then
    run bridge -details link show
    run bridge vlan show
fi
for filtering in /sys/class/net/*/bridge/vlan_filtering; do
    [ -r "$filtering" ] || continue
    printf '%s=' "$filtering"
    cat "$filtering" 2>/dev/null || true
done
if command -v uci >/dev/null 2>&1; then
    printf '\nSelected non-secret network bridge/VLAN fields:\n'
    uci -q show network 2>/dev/null | grep -E \
        '\.(type|device|ifname|ports|vid|vlan|vlan_filtering|bridge_empty)=' || \
        printf '<no matching UCI bridge/VLAN fields>\n'
fi

section 'wireless interface state (for NSS Wi-Fi correlation)'
if command -v iw >/dev/null 2>&1; then
    run iw dev
else
    printf '<iw unavailable>\n'
fi

section 'diagnostic safety statement'
printf '%s\n' \
    'Collection complete. No UCI values were changed, no filesystem was mounted,' \
    'no module was loaded/unloaded, and this script wrote no output file.'
