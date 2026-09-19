#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
TERRAFORM_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../terraform"))
KUBECONFIG = os.path.expanduser("~/.kube/eks-killer.conf")
KEY_PATH = os.path.join(TERRAFORM_DIR, "key-pair.pem")

def run_cmd(cmd, timeout=30):
    try:
        res = subprocess.run(cmd, shell=True, text=True, capture_output=True, timeout=timeout)
        return res.returncode, res.stdout.strip(), res.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "Timeout expired"

def get_tf_output(name):
    rc, out, _ = run_cmd(f"terraform -chdir='{TERRAFORM_DIR}' output -raw {name}")
    return out if rc == 0 else ""

def log(msg, t0=None):
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
    elapsed_str = f"[+{time.time() - t0:6.1f}s]" if t0 else "[   0.0s]"
    print(f"{ts} {elapsed_str} {msg}", flush=True)

def main():
    print("=" * 75)
    print("  EKS-KILLER: LIVE AWS FIS SPOT INTERRUPTION & HOT-POTATO BENCHMARK")
    print("=" * 75)

    master_eip = get_tf_output("master_eip") or "3.91.4.226"
    asg_name = get_tf_output("master_asg_name")
    exp_template_id = get_tf_output("spot_killer_experiment_id")

    print(f"Master EIP:       {master_eip}")
    print(f"Master ASG:       {asg_name}")
    print(f"FIS Template ID:  {exp_template_id}")
    print("=" * 75)

    # 1. Initial health check
    print("[1/5] Verifying initial cluster health...")
    rc, nodes_out, _ = run_cmd(f"kubectl --kubeconfig '{KUBECONFIG}' get nodes -o wide")
    if rc != 0:
        print(f"Error getting nodes: {nodes_out}")
        sys.exit(1)
    print(f"Current Node(s):\n{nodes_out}")

    # Determine current master instance ID
    rc, inst_out, _ = run_cmd(
        f"aws ec2 describe-instances --region {REGION} "
        f"--filters 'Name=ip-address,Values={master_eip}' "
        f"--query 'Reservations[0].Instances[0].InstanceId' --output text"
    )
    old_instance_id = inst_out if rc == 0 else ""
    print(f"Origin Master Instance ID: {old_instance_id}")

    input_prompt = "Triggering AWS Spot Interruption via AWS FIS..."
    print(f"\n[2/5] {input_prompt}")

    t0 = time.time()
    timeline = []

    # Start FIS experiment
    rc, exp_out, exp_err = run_cmd(
        f"aws fis start-experiment --region {REGION} "
        f"--experiment-template-id '{exp_template_id}' --output json"
    )
    if rc != 0:
        print(f"Failed to start FIS experiment: {exp_err}")
        sys.exit(1)

    exp_data = json.loads(exp_out)
    exp_id = exp_data.get("experiment", {}).get("id", "unknown")
    log(f"⚡ AWS FIS Experiment Started: {exp_id}", t0)
    timeline.append(("FIS_TRIGGER", time.time() - t0, f"Experiment {exp_id} started"))

    new_instance_id = None
    new_instance_ip = None
    eip_migrated = False
    new_node_detected = False
    cluster_recovered = False
    pods_running = False

    print("\n[3/5] Monitoring real-time hot-potato failover (Target: < 120s)...")
    fis_logged = False

    while time.time() - t0 < 300: # 5 minute cutoff
        elapsed = time.time() - t0

        # Check FIS experiment state
        if not fis_logged:
            rc_fis, fis_out, _ = run_cmd(
                f"aws fis get-experiment --region {REGION} --id '{exp_id}' "
                f"--query 'experiment.state.[status,reason]' --output json"
            )
            if rc_fis == 0 and fis_out:
                try:
                    fstatus, freason = json.loads(fis_out)
                    if fstatus == "running":
                        log(f"💥 AWS FIS is actively injecting 2-min Spot Interruption warning into IMDS!", t0)
                        timeline.append(("FIS_RUNNING", elapsed, "AWS FIS actively injecting IMDS warning"))
                        fis_logged = True
                    elif fstatus == "failed":
                        log(f"❌ FIS Experiment failed: {freason}", t0)
                        break
                except Exception:
                    pass

        # A. Check ASG instances
        if not new_instance_id:
            rc, asg_out, _ = run_cmd(
                f"aws autoscaling describe-auto-scaling-groups --region {REGION} "
                f"--auto-scaling-group-names '{asg_name}' "
                f"--query 'AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus]' --output json"
            )
            if rc == 0 and asg_out:
                try:
                    instances = json.loads(asg_out)
                    for inst in instances:
                        iid, state, health = inst
                        if iid != old_instance_id:
                            new_instance_id = iid
                            log(f"🆕 Replacement instance launched by ASG: {iid} ({state}, {health})", t0)
                            timeline.append(("ASG_SCALE_UP", elapsed, f"New instance {iid} detected in ASG"))
                            break
                except Exception:
                    pass

        # B. Check new instance private IP
        if new_instance_id and not new_instance_ip:
            rc, ip_out, _ = run_cmd(
                f"aws ec2 describe-instances --region {REGION} --instance-ids '{new_instance_id}' "
                f"--query 'Reservations[0].Instances[0].PrivateIpAddress' --output text"
            )
            if rc == 0 and ip_out and ip_out != "None":
                new_instance_ip = ip_out
                log(f"🌐 Replacement instance private IP assigned: {new_instance_ip}", t0)
                timeline.append(("IP_ASSIGNED", elapsed, f"Private IP {new_instance_ip}"))

        # C. Check EIP migration
        if not eip_migrated:
            rc, eip_out, _ = run_cmd(
                f"aws ec2 describe-addresses --region {REGION} --public-ips '{master_eip}' "
                f"--query 'Addresses[0].InstanceId' --output text"
            )
            if rc == 0 and eip_out and eip_out != "None":
                if eip_out != old_instance_id:
                    eip_migrated = True
                    log(f"🔀 EIP {master_eip} migrated to replacement master {eip_out}!", t0)
                    timeline.append(("EIP_MIGRATION", elapsed, f"EIP moved to {eip_out}"))

        # D. If EIP migrated, check Kubernetes API status
        if eip_migrated and not cluster_recovered:
            rc, node_check, _ = run_cmd(
                f"kubectl --kubeconfig '{KUBECONFIG}' get nodes --request-timeout=3s --no-headers"
            )
            if rc == 0 and node_check:
                lines = [l for l in node_check.splitlines() if l.strip()]
                # Check for Ready status on the active node
                ready_nodes = [l for l in lines if "Ready" in l and "NotReady" not in l]
                if not new_node_detected:
                    new_node_detected = True
                    log(f"📡 Kubernetes API is responding through EIP! Nodes:\n{node_check}", t0)
                    timeline.append(("API_ONLINE", elapsed, "K8s API reachable via EIP"))

                if ready_nodes:
                    cluster_recovered = True
                    log(f"✅ Replacement master is READY! Node: {ready_nodes[0].split()[0]}", t0)
                    timeline.append(("NODE_READY", elapsed, f"Master node is Ready ({ready_nodes[0].split()[0]})"))

        # E. If cluster recovered, check pods
        if cluster_recovered and not pods_running:
            rc, pod_check, _ = run_cmd(
                f"kubectl --kubeconfig '{KUBECONFIG}' get pods -A --no-headers"
            )
            if rc == 0 and pod_check:
                lines = [l for l in pod_check.splitlines() if l.strip()]
                calico_ready = any("calico-node" in l and "1/1" in l and "Running" in l for l in lines)
                apiserver_ready = any("kube-apiserver" in l and "1/1" in l and "Running" in l for l in lines)
                etcd_ready = any("etcd" in l and "1/1" in l and "Running" in l for l in lines)

                if calico_ready and apiserver_ready and etcd_ready:
                    pods_running = True
                    log(f"🚀 All control plane & CNI pods 1/1 Running!", t0)
                    timeline.append(("PODS_HEALTHY", elapsed, "All core pods Running (1/1)"))
                    break

        time.sleep(2)

    # 4. Check status of old instance
    print("\n[4/5] Checking termination status of origin instance...")
    rc, state_out, _ = run_cmd(
        f"aws ec2 describe-instances --region {REGION} --instance-ids '{old_instance_id}' "
        f"--query 'Reservations[0].Instances[0].State.Name' --output text"
    )
    old_state = state_out if rc == 0 else "unknown"
    log(f"Origin instance {old_instance_id} state: {old_state}", t0)
    timeline.append(("ORIGIN_TERMINATED", time.time() - t0, f"Origin instance {old_instance_id} is {old_state}"))

    # 5. Summary Table
    print("\n" + "=" * 75)
    print("  HOT-POTATO FAILOVER BENCHMARK RESULTS")
    print("=" * 75)
    print(f"{'STAGE':<20} | {'ELAPSED':<10} | {'DETAILS'}")
    print("-" * 75)
    for event, sec, detail in timeline:
        print(f"{event:<20} | {sec:6.1f}s   | {detail}")
    print("=" * 75)

    if cluster_recovered:
        total_time = next((sec for ev, sec, _ in timeline if ev == "NODE_READY"), time.time() - t0)
        print(f"\n🎉 SUCCESS: Hot-potato failover completed in {total_time:.1f}s!")
        if total_time < 120:
            print(f"⚡ BEAT SPOT INTERRUPTION TIMER (120s) by {120 - total_time:.1f} seconds!")
        else:
            print(f"⚠️ Failover took longer than 120 seconds ({total_time:.1f}s).")
    else:
        print("\n❌ FAILED: Cluster did not recover within the timeout period.")

    # Print final cluster state
    print("\n--- Final Node Status ---")
    _, out, _ = run_cmd(f"kubectl --kubeconfig '{KUBECONFIG}' get nodes -o wide")
    print(out)
    print("\n--- Final Pod Status ---")
    _, out, _ = run_cmd(f"kubectl --kubeconfig '{KUBECONFIG}' get pods -A")
    print(out)

if __name__ == "__main__":
    main()

