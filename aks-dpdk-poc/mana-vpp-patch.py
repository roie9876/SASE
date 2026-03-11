import re
import sys

with open("/tmp/vpp/src/plugins/dpdk/device/init.c", "r") as f:
    content = f.read()

# Find our MANA patch and replace with skip-UIO version
old = """    /* Microsoft Azure MANA */
    else if (d->vendor_id == 0x1414 && d->device_id == 0x00ba)
      ;
    else"""

new = """    /* Microsoft Azure MANA - bifurcated driver, skip UIO bind */
    else if (d->vendor_id == 0x1414 && d->device_id == 0x00ba)
      {
        /* MANA uses kernel mana driver + rdma-core verbs + DPDK PMD */
        /* No UIO/VFIO binding needed - skip to end of loop */
        goto next_device;
      }
    else"""

if old not in content:
    print("ERROR: Could not find MANA patch marker!")
    sys.exit(1)

content = content.replace(old, new)

# Now add the next_device label before the closing brace of the for loop
old2 = "  vec_free (pci_addr);\n  vlib_pci_free_device_info (d);\n}"
new2 = "next_device:\n  vec_free (pci_addr);\n  vlib_pci_free_device_info (d);\n}"

if old2 not in content:
    print("ERROR: Could not find loop end marker!")
    sys.exit(1)

content = content.replace(old2, new2, 1)  # Replace only first occurrence

with open("/tmp/vpp/src/plugins/dpdk/device/init.c", "w") as f:
    f.write(content)

print("Patched successfully")
