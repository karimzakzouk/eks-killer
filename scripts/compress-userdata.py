#!/usr/bin/env python3
import sys, os, json

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

role = sys.argv[1] if len(sys.argv) > 1 else "master"
q = json.load(sys.stdin)

with open(f"scripts/{role}/bootstrap-{role}.sh.tpl") as f:
    tpl = f.read()

scripts = {
    "pyreceiver_py":      open("scripts/shared/pyreceiver.py").read(),
    "handoff_port":       str(q.get("handoff_port", "7777")),
    "common_core_sh":     open("scripts/shared/common-core.sh").read(),
    "snapshot_loop_sh":   open("scripts/shared/snapshot-loop.sh").read(),
    "watcher_master_sh":  open("scripts/shared/watcher-master.sh").read(),
    "watcher_worker_sh":  open("scripts/shared/watcher-worker.sh").read(),
    "handoff_sh":         open("scripts/shared/handoff.sh").read(),
    "receiver_master_sh": open("scripts/shared/receiver-master.sh").read(),
    "receiver_worker_sh": open("scripts/shared/receiver-worker.sh").read(),
    "systemd_snapshot_loop_service": open("scripts/shared/systemd/snapshot-loop.service").read(),
    "systemd_watcher_master_service": open("scripts/shared/systemd/watcher-master.service").read(),
    "systemd_watcher_worker_service": open("scripts/shared/systemd/watcher-worker.service").read(),
    "systemd_receiver_service": open("scripts/shared/systemd/receiver.service").read(),
    "systemd_eip_lo_service": open("scripts/shared/systemd/eip-lo.service.tpl").read(),
    "kubernetes_version": str(q.get("kubernetes_version", "1.30")),
    "aws_region":         str(q.get("aws_region", "us-east-1")),
    "eip_allocation_id":  str(q.get("eip_allocation_id", "")),
    "eip_public_ip":      str(q.get("eip_public_ip", "")),
    "pod_cidr":           str(q.get("pod_cidr", "192.168.0.0/16")),
}

result = tpl
for key, val in scripts.items():
    result = result.replace("${" + key + "}", val)

print(json.dumps({"userdata": result}))
