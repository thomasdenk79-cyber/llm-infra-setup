# eGPU stability policy

This host uses a Razer Core X V2 over Thunderbolt/USB4 with an NVIDIA RTX PRO 6000.
The host previously showed NVIDIA `Failed GPU reg read: 0xffffffff` messages and
intermittent freezes after sustained load. Runtime power management is therefore
disabled for PCIe and Thunderbolt devices, PCIe ASPM is disabled at boot, USB
autosuspend is disabled, CPU scaling is pinned to `performance`, and NVIDIA
persistence mode is enabled. This deliberately trades idle power for link stability.

The policy is applied by `scripts/host-power-stability.sh`, the systemd unit of the
same name, and `rules/80-egpu-no-runtime-pm.rules`. Keep this enabled on eGPU hosts;
do not re-enable `power-profiles-daemon` without testing long-running GPU workloads.
