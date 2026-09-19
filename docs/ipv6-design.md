# IPv6 design

Purpose: where IPv6 stands today, what this firmware already provides, and the
preferred integration paths for the future campus-native-IPv6 split-WAN setup.

Status: design only. **Do not implement any integration option until the real
campus allocation has been measured** (see *What to measure first*).

## Goals

- Correct, standards-compliant IPv6 behavior whenever a native prefix exists.
- No transition hacks by default: no NAT66, no tunneling, until measurements
  force a choice.
- Keep the IPv4 path (Telecom PPPoE) untouched by IPv6 experiments.

## Current reality (design context, not configuration)

- WAN is China Telecom PPPoE, **IPv4-only**; the WAN interface receives a
  private 10.203.x.x address behind upstream CGNAT.
- A previous campus-broadband PPPoE provided native IPv6. The future plan: a
  small Linux host on the same upstream L2 takes the campus PPPoE for IPv6,
  while the Redmi AC2100 keeps Telecom IPv4.
- Desired end state: LAN IPv4 -> AC2100 -> Telecom; LAN IPv6 -> campus router
  -> IPv6 Internet.

## What this firmware already ships

[../config/base.config](../config/base.config) pins the standard OpenWrt IPv6
stack (confirmed upstream defaults):

| Piece | Role |
| --- | --- |
| `odhcp6c` | WAN-side DHCPv6 client: IA_NA address and IA_PD prefix delegation |
| `odhcpd-ipv6only` | LAN-side Router Advertisement + DHCPv6 server |
| default ULA | OpenWrt generates a ULA /48 and announces it on the LAN by default (local-only addressing, independent of any ISP) |
| fw4 | default IPv6 firewalling: DHCPv6 input allowed on WAN, no unsolicited inbound forwarding |

So the moment a real prefix appears on a WAN6 interface, the router behaves
like a normal OpenWrt IPv6 router with zero extra packages.

## The future split-WAN design

```
                        Internet
                       /        \
        Telecom PPPoE            Campus PPPoE
        IPv4-only, CGNAT         native IPv6
               |                       |
       +-------v--------+      +-------v--------+
       | Redmi AC2100   |      | Linux mini-PC  |
       | (this firmware)|      | (campus router)|
       +-------+--------+      +-------+--------+
               |       same LAN segment |
               +----------+-------------+
                          |
                      LAN clients
           IPv4 default gateway -> AC2100   (via DHCPv4)
           IPv6 default gateway -> mini-PC  (via ICMPv6 RA)
```

## Integration options, in preference order

**(a) Campus box as the on-link IPv6 router (preferred).** The mini-PC sends
Router Advertisements on the LAN; clients autoconfigure against it directly.
The AC2100 is then a plain IPv6 host on that segment (its own LAN-side
RA/DHCPv6 disabled, or left announcing only ULA). Simplest and most
standards-clean; no coupling between the two boxes. Requires the campus
allocation to put clients on-link with the mini-PC (a shared /64).

**(b) DHCPv6-PD sub-delegation from the campus box.** The mini-PC delegates a
sub-prefix (e.g. a /60) to the AC2100's WAN6 via DHCPv6-PD (`odhcp6c` on the
client side; wide-dhcp6c or odhcpd on the mini-PC side). The AC2100 then runs
odhcpd for the LAN as a real IPv6 router. Preferred when the AC2100 should own
the LAN for both address families. Requires the campus prefix to be large
enough and stable enough to sub-delegate.

**(c) Routed prefix (static).** The campus box installs a static route for a
dedicated prefix (e.g. a /60) toward the AC2100's address on the shared
segment; the AC2100 routes it to the LAN. Works when DHCPv6-PD is unavailable
but the campus prefix is stable and the mini-PC's configuration is yours.

**(d) NDP proxy / relay fallback.** When the campus network is L2-locked to a
single on-link /64 and no delegation is possible: odhcpd in NDP-proxy/relay
mode so LAN clients appear as neighbors on the campus segment. Functional but
ugly: no real routing, per-host state to maintain.

**(e) NAT66 — last resort only.** fw4 can masquerade IPv6 and it would
"work", but it throws away the one thing native IPv6 is for — end-to-end
reachability, including better Tailscale direct paths (see
[tailscale.md](tailscale.md)) — and adds state for zero gain over (a). Only
if every option above is proven impossible.

## What to measure first (before implementing anything)

On the campus connection (from the mini-PC or a test client):

| Question | How | Result |
| --- | --- | --- |
| What is delegated: on-link /64 only, or a routed prefix (/56–/60)? | watch DHCPv6/ICMPv6 on the WAN: `tcpdump -i <wan> -n 'icmp6 or udp port 547'`; client side `odhcp6c -v` / `ifstatus wan6` equivalents | NOT MEASURED |
| Is IA_PD honored at all? | request a delegation with `odhcp6c -v` and look for `IA_PD` in the replies | NOT MEASURED |
| Prefix stability across reconnects? | reconnect the campus PPPoE, compare `ip -6 addr` / the delegated prefix | NOT MEASURED |
| Do RAs arrive cleanly on the LAN? | `tcpdump -i <lan> -n 'icmp6 and ip6[40] == 134'`; `ip -6 route` on clients | NOT MEASURED |
| What do the router logs say? | `logread -e odhcp6c`, `logread -e odhcpd` | NOT MEASURED |

Only after the *Result* column holds real values does one of options (a)–(e)
get chosen and configured.
