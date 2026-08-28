# system_server Crash / Soft-Reboot — Cause Checklist

Symptom: `system_server` FATAL → `audio.service` SIGSEGV → framework restart (looks like
soft-reboot).

## Evidence (latest: veux_logs_20260828_131940)
- Crash at `logcat_all.txt:3626`: `synchronizeKernelRCU failed: -24` from
  `BpfNetMaps.swapActiveStatsMap()` → `NetworkStatsFactory.requestSwapActiveStatsMapLocked()`.
- `13:08:22.486` `audio.service` SIGSEGV (null deref, HwBinder:932_1).
- `13:08:23.246` `boot_progress_start` → full userspace restart (the "soft-reboot").
- Kernel dmesg: NO panic / RCU stall / watchdog / OOM. Only `rcupdate.rcu_expedited=1` on cmdline
  (normal) + `NetBpfLoad bpf_create_map[tether_error_map] -> 4` (BPF OK at boot).
- Conclusion: **userspace death, kernel stable.**

## Checklist (ranked — tick with `./veux_master_collector.sh ksu` or `crash` after reflash)

- [ ] **#1 Spoofed KSU Manager** (`yagyzd.amjlhq.kkingw`, v3.1.0-spoofed) → broken `ksud`
      returns `-24` on supercall. FIX: official KernelSU-Next Manager + `ksun-full-clean.sh`.
      (PRIMARY cause in 131940)
- [ ] **#2 ADSP/FastRPC HAL** (sensor/bio) → system_server death on unlock. (prior logs 153153/153610)
- [ ] **#3 Stale metamodule** `hybrid_mount/update` flag + `/data/adb/metamodule` symlink →
      `ksud` bad state. Check `ksu/module_flags.txt` in capture.
- [ ] **#4 `rcupdate.rcu_expedited=1`** interaction (nebula-aligned; test-flip ONLY if #1 persists).
- [ ] **#5 BPF map limit** (`EMFILE` -24 on `bpf()` map swap — could be REAL kernel tuning, not
      Manager). Check `ksu/maxfiles.txt`, `ksu/bpf_map_count.txt`, `ksu/buddyinfo.txt`.
- [ ] **#6 `audio.service` SIGSEGV** cascade — independent or binder victim.
      Check `ksu/tombstone_audio.txt` for null-deref.
- [ ] **#7 memcg LRU underflow** — clamped in `mm/memcontrol.c`; verify absent in new log.
- [ ] **#8 Vendor HAL timeout** (`SensorService linkToDeath -38`).
- [ ] **#9 `androidboot.debuggable=1`** extra tracing stress (low suspicion).
- [ ] **#10 KSU supercall kernel bug** — `[ksu_driver]` IOCTL returns `-24` for legit request.
      Check `ksu/ksu_dmesg.txt`. Would need a kernel fix, not userspace.

## Ruled OUT by 131940
kernel panic · SELinux AVC on ksu · OOM/lowmemory · binder failed-transaction storm · LRU underflow

## Collector targets
`veux_master_collector.sh ksu` → `ksu/` dir with:
`manager_packages.txt` (spoofed detect), `module_flags.txt` (#3), `maxfiles.txt`+`bpf_map_count.txt`
(#5), `rcu_cmdline.txt` (#4), `tombstone_audio.txt` (#6), `ksu_dmesg.txt` (#10), `ksu_version.txt`.
