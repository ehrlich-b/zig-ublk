# VM Testing

VM-based integration tests for zig-ublk. Required because ublk needs root + kernel 6.8+.

## Why a VM?

WSL2 doesn't have `ublk_drv` module. We need a real Linux VM with:
- Ubuntu 24.04+ (kernel 6.8+)
- `ublk_drv` module available

## VM Setup

**Requirements:**
- Ubuntu 24.04+ (kernel 6.8+)
- 2GB+ RAM
- SSH server running
- `ublk_drv` module: `sudo modprobe ublk_drv`

**SSH config:** Create `Makefile.local`:
```makefile
VM_HOST = 192.168.x.x
VM_USER = youruser
VM_PASS = yourpass
```

Or use environment variables: `UBLK_VM_HOST`, `UBLK_VM_USER`, `UBLK_VM_PASS`

## Test Commands

```bash
make vm-check         # Verify VM config
make vm-copy          # Copy binary to VM
make vm-simple-e2e    # Basic I/O test
make vm-reset         # Hard reset VM (if stuck)
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Connection refused | Check VM IP and SSH |
| Module not found | `sudo modprobe ublk_drv` |
| Device creation fails | Check `dmesg \| tail -20` |
| Test hangs | `make vm-reset` |

## VM Creation (Multipass)

Quick setup using Ubuntu Multipass:

```bash
# Create VM
multipass launch --name ublk-test --cpus 2 --memory 2G --disk 10G 24.04

# Get IP
multipass info ublk-test | grep IPv4

# SSH in (default user: ubuntu)
multipass shell ublk-test

# Inside VM: enable ublk
sudo modprobe ublk_drv
```

Then configure `Makefile.local` with the VM's IP.
