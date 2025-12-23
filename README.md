# Router Patches

Scripts and configuration files for patching and managing my home routers

This might not work for you, but can be a good starting point for your own tweaks

## Project Structure

- `xiaomi-be6500pro/` - Router-specific files for BE6500Pro
  - `data/sing-box/config.json` - Sing-box proxy configuration
  - `data/ssh/` - SSH keys for remote access

- `xiaomi-downgrade/` - Router firmware downgrade utilities
  - `dnsmasq.conf` - DNS configuration
  - `downgrade.sh` - Downgrade automation

## Deployment

Files are deployed to the router using rsync:

```bash
rsync -av xiaomi-be6500pro/ root@router-ip:/
```

This copies all configuration files, scripts, and SSH keys to the appropriate locations on the router. The crontab entries ensure patches are automatically applied on schedule.

