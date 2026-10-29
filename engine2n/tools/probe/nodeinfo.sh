echo "host=$(hostname) kernel=$(uname -r) up: $(uptime | sed 's/.*up //')"
echo "amdgpu: $(modinfo -n amdgpu) srcver=$(cat /sys/module/amdgpu/srcversion 2>/dev/null) ver=$(modinfo -F version amdgpu 2>/dev/null)"
cat /proc/cmdline | tr ' ' '\n' | grep -E 'amdgpu|ttm|iommu|amd_iommu|gtt|pcie|mitig' | tr '\n' ' '; echo
D=$(ls -d /sys/class/drm/card*/device 2>/dev/null | while read d; do [ -f $d/gpu_busy_percent ] && echo $d; done | head -1); echo "gpu dev=$D"
for f in power_dpm_force_performance_level pp_power_profile_mode gpu_busy_percent mem_info_vram_total mem_info_gtt_total mem_info_gtt_used; do printf '%s: ' $f; head -c 400 $D/$f 2>/dev/null | tr '\n' ' ' | cut -c1-200; echo; done
printf 'pp_dpm_sclk: '; cat $D/pp_dpm_sclk 2>/dev/null | tr '\n' ' '; echo
printf 'pp_dpm_mclk: '; cat $D/pp_dpm_mclk 2>/dev/null | tr '\n' ' '; echo
printf 'pp_dpm_fclk: '; cat $D/pp_dpm_fclk 2>/dev/null | tr '\n' ' '; echo
cat /sys/firmware/acpi/platform_profile 2>/dev/null | sed 's/^/platform_profile: /'
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null | sed 's/^/cpu governor: /'
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null | sed 's/^/cpu epp: /'
powerprofilesctl get 2>/dev/null | sed 's/^/ppd: /'
cat /sys/class/power_supply/AC*/online 2>/dev/null | sed 's/^/AC online: /'
free -g | sed -n 2p
echo "top CPU:"; top -bn1 -o %CPU | sed -n 8,13p
