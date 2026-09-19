# Benchmarks

Purpose: the reproducible methodology for performance-testing this firmware on
real hardware — and the only place results are allowed to live.

Status: methodology defined; **no hardware tests have been run**. Every
results cell below is `NOT TESTED`.

Hard rule: numbers enter this file only from real measurements on the target
hardware, with the *Config under test* block filled in. Estimates, spec-sheet
values, and "expected" numbers are never recorded as results.

## Test rig

- **Wired peer**: one Linux host on gigabit Ethernet running `iperf3 -s` as
  the measurement server; the same host runs client-side tools (`flent` if
  available).
- **Wi-Fi client**: a fixed client at a fixed near-field position (~1–3 m,
  clear line of sight) for 5 GHz runs; record client hardware and position per
  run.
- **RF environment**: not controlled. Record channel, width, regdomain
  country, and a scan snapshot (`iwinfo wlan1 scan`) alongside every Wi-Fi
  result; repeat runs and report medians.
- **Router side**: SSH session for counters. Baseline snapshot before each
  scenario: `free -m`, `cat /proc/interrupts`, `cat /proc/softirqs`,
  `ethtool -S <wan>`, `conntrack -S`.

## Config under test (fill in per run)

| Field | Value |
| --- | --- |
| Repository commit / CI run | NOT TESTED |
| Image SHA256 (from SHA256SUMS) | NOT TESTED |
| Flavor (base / full) | NOT TESTED |
| OpenWrt commit | `d266501ad6188cce279a487b1ce61f4f327cd496` (v25.12.2) |
| Kernel | 6.12.74 |
| `flow_offloading` / `flow_offloading_hw` | NOT TESTED |
| WAN type (DHCP / PPPoE) | NOT TESTED |
| Wi-Fi channel / width / country | NOT TESTED |

## What to record (every scenario)

- throughput: iperf3 sender/receiver rates, TCP retransmits;
- latency series where applicable (`ping -D` timestamps or flent);
- per-core CPU: `mpstat -P ALL 1` if sysstat is available, otherwise `htop`
  (ships in the full flavor);
- `/proc/softirqs` and `/proc/interrupts` deltas over the run window;
- NIC errors/drops: `ethtool -S <iface>` deltas;
- Wi-Fi: `iw dev wlan0 station dump` / `iw dev wlan1 station dump` (tx
  retries, signal, bitrate);
- conntrack: `conntrack -S` counters and `dmesg` for `nf_conntrack: table
  full`;
- memory: `free -m` before/after.

## Scenarios

### Wired termination: LAN -> router

The router terminates the traffic (no routing involved). Command skeletons:
`iperf3 -c <router-lan-ip>`, reversed `iperf3 -c <router-lan-ip> -R`, parallel
`iperf3 -c <router-lan-ip> -P 4`.

| Direction | Throughput | Retransmits | CPU notes |
| --- | --- | --- | --- |
| client -> router | NOT TESTED | NOT TESTED | NOT TESTED |
| router -> client | NOT TESTED | NOT TESTED | NOT TESTED |
| 4 parallel streams | NOT TESTED | NOT TESTED | NOT TESTED |

### Routed IPv4 (NAT): LAN <-> WAN

The trio that isolates the fast path ([performance.md](performance.md)):
offload off, software flow offload, hardware flow offload. WAN configured as
plain Ethernet DHCP. Command skeletons: `iperf3 -c <wan-side-server>` and
`-R`.

| Variant | client -> server | server -> client | softirq/CPU delta | Notes |
| --- | --- | --- | --- | --- |
| offload off (baseline) | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED |
| sw flow offload | NOT TESTED | NOT TESTED | NOT TESTED | verify `[OFFLOAD]` in `conntrack -L` |
| hw flow offload | NOT TESTED | NOT TESTED | NOT TESTED | verify `[HW_OFFLOAD]` in `conntrack -L` |

### PPPoE WAN

The same trio over the real PPPoE WAN. This is the decisive test for the
PPPoE hardware-offload claim ([performance.md](performance.md)).

| Variant | down | up | softirq/CPU delta | Notes |
| --- | --- | --- | --- | --- |
| offload off | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED |
| sw flow offload | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED |
| hw flow offload | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED |

### Wi-Fi: 5 GHz LAN throughput (80 MHz, near-field)

Per candidate channel, at least two channels, using the selection methodology
in [performance.md](performance.md#wi-fi-mt76-performance-notes): scan, pick
least-utilized, then measure. Command skeletons: `iperf3 -c <wired-server>`
from the Wi-Fi client, and `-R`.

| Channel | Width | client -> wired | wired -> client | retries (iw) | Signal |
| --- | --- | --- | --- | --- | --- |
| NOT TESTED | 80 MHz | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED |
| NOT TESTED | 80 MHz | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED |

### Internet down/up via ISP

Methodology only — results depend on the ISP and the test server. Public
iperf3 server or speedtest-style tooling from a wired client over the
production PPPoE; record server identity and time of day.

| Direction | Throughput | Notes |
| --- | --- | --- |
| down | NOT TESTED | NOT TESTED |
| up | NOT TESTED | NOT TESTED |

### Latency under load

Preferred: `flent rrul` from the wired client against a netserver peer
(client-side tooling, if available). Fallback: `ping -D <gateway>` sampled
during the routed scenarios, comparing idle vs loaded latency distributions.

| Condition | Tool | Result |
| --- | --- | --- |
| idle baseline | NOT TESTED | NOT TESTED |
| loaded, fast path on | NOT TESTED | NOT TESTED |
| loaded, fast path off | NOT TESTED | NOT TESTED |

### conntrack stress

Many-flows run: `iperf3 -c <server> -P 64` (and higher if the table
survives), while watching `dmesg` for `nf_conntrack: table full, dropping
packet` and `conntrack -S` for insert_failed / drop counters. The outcome
decides whether `net.netfilter.nf_conntrack_max` tuning graduates from
candidate to default ([performance.md](performance.md)).

| Flows | table-full events | conntrack -S anomalies | Verdict |
| --- | --- | --- | --- |
| 64 | NOT TESTED | NOT TESTED | NOT TESTED |
| NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED |

### Wi-Fi error/retry capture

During the 5 GHz scenario, snapshot `iw dev wlan0 station dump` /
`iw dev wlan1 station dump` (retries, signal, tx bitrate) and `ethtool -S` on
the Ethernet side, before and after each run.

| Radio | Retries baseline | Retries under load | Notes |
| --- | --- | --- | --- |
| wlan0 (2.4 GHz) | NOT TESTED | NOT TESTED | NOT TESTED |
| wlan1 (5 GHz) | NOT TESTED | NOT TESTED | NOT TESTED |

### Tailscale: direct vs DERP

After Tailscale is configured ([tailscale.md](tailscale.md)): record
`tailscale status` path type per peer (direct / relay), `tailscale ping
<peer>` latency, then `iperf3` over the tailnet to the peer. Repeat if/when
native IPv6 exists — the direct-rate change is the hypothesis under test.

| Peer | Path (direct / relay) | ping | iperf3 over tailnet |
| --- | --- | --- | --- |
| NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED |

### IPv6

**PENDING** — blocked on campus IPv6 availability; see
[ipv6-design.md](ipv6-design.md). No rows until a native prefix exists.
