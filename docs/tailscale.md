# Tailscale

Purpose: why Tailscale ships in this firmware, what is (and is not)
preconfigured, and what native IPv6 would change.

Status: package selected (full flavor); nothing auto-starts and no keys exist
in the image. NAT-behavior notes below come from the current network's
observed reality plus upstream Tailscale documentation.

## Why it is here (design context)

The current WAN is Telecom PPPoE behind upstream CGNAT:

- the WAN address is private (10.203.x.x) — **no inbound IPv4 is possible**,
  so port forwarding is dead on arrival;
- UDP outbound works;
- the stock router supports UPnP / NAT-PMP / PCP, but the upstream CGNAT still
  blocks unsolicited inbound traffic;
- Tailscale's own diagnostics report `MappingVariesByDestIP` —
  endpoint-dependent ("hard") NAT — which forces some peer connections onto
  DERP relays instead of direct paths;
- Tailscale also reports IPv6 unavailable on this network today.

That profile — CGNAT, no IPv6 yet, hard NAT — is exactly the case Tailscale
exists for.

## What the firmware ships

- Package `tailscale` (version 1.94.1 at the pinned packages feed — confirmed
  upstream), listed in
  [../config/packages-full.list](../config/packages-full.list) (full flavor
  only) and installed from the official precompiled feed by the ImageBuilder.
- The init script is present, but the service is **not started and not
  joined**: there is no auth key in the image, no `--auth-key` anywhere, no
  auto-join logic. First boot is dark until you run `tailscale up` yourself.
- Flash cost: one `tailscaled` binary plus a `tailscale` CLI symlink, stripped
  by the OpenWrt build system (no UPX; build tags omit unused subsystems —
  confirmed in the pinned feed Makefile). The exact in-image cost is measured
  per build (compare base vs full artifact sizes in the CI metadata) rather
  than estimated here.

## Configuring it (after flashing, on your own router)

Documentation-only sketch; this repository never does it for you:

```
tailscale up --auth-key=<tskey-auth-...>          # or interactive login
tailscale up --advertise-routes=192.168.31.0/24   # subnet-router example (your LAN)
```

- **Subnet router**: advertising the LAN prefix (the stock default LAN is
  192.168.31.0/24, router at 192.168.31.1) makes every LAN device reachable
  over the tailnet; route approval happens in the Tailscale admin console, and
  the tailscale interface needs the usual OpenWrt firewall-zone treatment.
- **Exit node**: the router can offer itself as an exit node, but remember the
  WAN behind it is CGNAT IPv4-only with unmeasured throughput — an exit node
  here is a convenience feature, not a performance feature.
- No secrets ever enter this repository;
  [../scripts/verify-repo.sh](../scripts/verify-repo.sh) hard-fails on
  `tskey-` material.

## What native IPv6 would change

Tailscale strongly prefers direct UDP paths and falls back to DERP relays when
NAT traversal fails. With `MappingVariesByDestIP` NAT on the IPv4 side, some
peers will always relay. Once native IPv6 exists (see
[ipv6-design.md](ipv6-design.md)), v6 direct paths have no NAT to traverse,
which should materially raise the direct-connection rate and cut relay
latency. **This claim requires measurement**: the Tailscale scenario in
[benchmarks.md](benchmarks.md) records direct-vs-DERP before and after.

Verification commands once the network is up: `tailscale status` (per-peer
path: direct vs relay), `tailscale ping <peer>` (shows whether the path
punched through), MagicDNS for names.

## Resource cost on 128 MiB

tailscaled's resident footprint on this class of device is on the order of
tens of MB — **estimate, to be verified** with `ps` / `free -m` on real
hardware (see the memory budget in [performance.md](performance.md)). On a
128 MiB router that is affordable while idle discipline elsewhere holds; it is
one more reason the service stays opt-in.
