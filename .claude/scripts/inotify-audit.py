#!/usr/bin/env python3
"""Audit inotify fd/watch consumption per UID and process.

Note: st_ino is useless for dedup here - every anon_inode shares one inode in the
anon_inodefs superblock. So count fds and accept that fork-inherited fds over-count
instances slightly. /proc/[0-9]* lists thread-group leaders only, so threads don't
inflate the count.
"""
import os, glob, collections

def uid_of(pid):
    try:
        for line in open(f"/proc/{pid}/status"):
            if line.startswith("Uid:"):
                return int(line.split()[1])
    except Exception:
        pass
    return None

def read(p, default="?"):
    try:
        return open(p).read().strip()
    except Exception:
        return default

def age_secs(pid):
    try:
        st = int(open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()[19])
        return int(float(read("/proc/uptime", "0 0").split()[0]) - st / os.sysconf("SC_CLK_TCK"))
    except Exception:
        return -1

by_uid = collections.Counter()
rows = collections.defaultdict(lambda: [0, 0])      # (uid, comm, pid) -> [fds, watches]

for fdpath in glob.glob("/proc/[0-9]*/fd/*"):
    try:
        if os.readlink(fdpath) != "anon_inode:inotify":
            continue
    except OSError:
        continue
    pid = fdpath.split("/")[2]
    fd = fdpath.rsplit("/", 1)[1]
    uid = uid_of(pid)
    if uid is None:
        continue
    by_uid[uid] += 1
    try:
        w = sum(1 for l in open(f"/proc/{pid}/fdinfo/{fd}") if l.startswith("inotify wd:"))
    except OSError:
        w = 0
    k = (uid, read(f"/proc/{pid}/comm"), pid)
    rows[k][0] += 1
    rows[k][1] += w

limit = int(read("/proc/sys/fs/inotify/max_user_instances"))
wlimit = int(read("/proc/sys/fs/inotify/max_user_watches"))
print(f"HOST {os.uname().nodename}  max_user_instances={limit}  max_user_watches={wlimit}")
print("inotify fds per UID (the limit is charged per-UID):")
for uid, n in by_uid.most_common():
    print(f"   uid={uid:<6} {n:4d}/{limit}" + ("   <-- AT/OVER LIMIT" if n >= limit else ""))

print("\ntop holders (fds / watches / process age):")
agg = collections.Counter()
for (uid, comm, pid), (f, w) in rows.items():
    agg[(uid, comm)] += f
for (uid, comm), f in agg.most_common(14):
    pids = [(p, v) for (u, c, p), v in rows.items() if u == uid and c == comm]
    tw = sum(v[1] for _, v in pids)
    ages = sorted(age_secs(p) for p, _ in pids)
    print(f"   uid={uid:<6} {f:4d} fds  {tw:6d} watches  {comm:22s} "
          f"nproc={len(pids):3d}  oldest={ages[-1] if ages else -1}s")

zero = sum(1 for v in rows.values() if v[1] == 0)
print(f"\nprocesses holding inotify fds with ZERO watches: {zero} of {len(rows)}")
for (uid, comm, pid), (f, w) in sorted(rows.items(), key=lambda x: -x[1][0])[:10]:
    if w == 0:
        print(f"   uid={uid} pid={pid} {comm} fds={f} watches=0 age={age_secs(pid)}s")
