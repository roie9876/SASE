with open('azure_sase_poc_lab.md', 'r') as f:
    content = f.read()

phase_4_log = """## Phase 4: Deploying the Open-Source VPP Router 

Now that the hardware is exposed to Kubernetes via the Device Plugin, we can deploy a Pod that actually requests this physical Virtual Function (VF).

**1. Creating the VPP Pod Manifest:**
This Pod requests the SR-IOV network resource, which triggers Multus to inject the physical interface bypassing the Kubelet's standard CNI.

```bash
cat << 'EOF' > vpp-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: vpp-router
  annotations:
    k8s.v1.cni.cncf.io/networks: sriov-network
spec:
  containers:
  - name: vpp
    image: ubuntu:22.04
    command: ["sleep", "infinity"]
    securityContext:
      privileged: true # Required for DPDK/kernel bypass operations
    resources:
      requests:
        intel.com/sriov_net: '1' # Instructs K8s to assign exactly 1 physical VF
      limits:
        intel.com/sriov_net: '1'
