# OpenChamber Proxy

Proxies `opencode.sammohr.dev` to the OpenChamber instance on smortress
via Tailscale (Caddy on smoresnet → smortress:3000).

## Architecture

```
Phone → Caddy (smoresnet:443) → Tailscale → OpenChamber (smortress:3000)
```

No more SSH tunnel — smoresnet reaches smortress directly over Tailscale MagicDNS.

## Deploy

```bash
scp Caddyfile deploy-smoresnet.sh smores@smoresnet:~
ssh smores@smoresnet 'bash ~/deploy-smoresnet.sh'
```

## Password

OpenChamber has its own `--ui-password` auth. Set it on smortress:

```bash
echo "your-password" > ~/.config/openchamber/ui-password
systemctl --user restart openchamber
```

## DNS

Point `opencode.sammohr.dev` to smoresnet's public IP (`45.79.90.184`) via Namecheap.
