# Self-hosted AmneziaWG roadmap

## Scope

The project will support self-hosted AmneziaWG guest connections only. Amnezia
Premium/API subscriptions and full-access self-hosted keys are out of scope.
The accepted input is a guest `vpn://` link exported for one AmneziaWG
protocol. Native `.conf` import can use the same validation layer later.

The official Amnezia client creates a guest link by serializing JSON,
compressing it with Qt `qCompress`, encoding it as URL-safe Base64, and adding
the `vpn://` prefix. Before export it removes SSH username, password and port,
keeps only the selected protocol container, and includes the generated client
configuration. See the upstream implementations of
[`generateConnectionConfig`](https://github.com/amnezia-vpn/amnezia-client/blob/dcf53b989e684a2e3e3f7f5c090001fb2def73b9/client/core/controllers/selfhosted/exportController.cpp)
and [`AwgProtocolConfig`](https://github.com/amnezia-vpn/amnezia-client/blob/dcf53b989e684a2e3e3f7f5c090001fb2def73b9/client/core/models/protocols/awgProtocolConfig.cpp).

## Runtime architecture

```text
Telegram bot / local CLI
          |
          v
 primary / backup profile store (VLESS or AWG)
          |
          v
 failover supervisor selects one slot
          |
     +----+--------------------+
     |                         |
 VLESS adapter             AWG adapter
 Xray outbound       amneziawg-go + awg interface
     |                         |
     +------------+------------+
                  v
       one stable local SOCKS5 endpoint
                  v
             Keenetic Proxy0
```

AWG needs its own tunnel client in Entware. It does not itself provide SOCKS5.
The stable SOCKS5 endpoint can remain an Xray inbound; for an AWG slot its
direct outbound is bound to the AWG interface. This preserves the current
Keenetic `Proxy0` integration and lets VLESS and AWG occupy either the primary
or backup slot.

The distributed artifacts remain two self-contained installers, FULL and
MINIMAL. Additional runtime executables and small helpers are embedded inside
those installers rather than published as separate user-facing installation
choices.

## Delivery stages

1. **Source boundary and parser**
   - Decode Qt-compressed `vpn://` payloads with strict size limits.
   - Accept exactly one `amnezia-awg` or `amnezia-awg2` guest container.
   - Reject Premium/API, full-access credentials and non-AWG containers.
   - Validate native interface, peer, keys, endpoint, routes and AWG fields.
   - Never print or JSON-serialize the private native configuration.

2. **AWG runtime probe**
   - Pin maintained `amneziawg-go` and tools versions with immutable commits.
   - Cross-build and run architecture smoke tests for `arm64` and `mipsle`.
   - Measure memory on the 40 MB target before including AWG in MINIMAL.
   - Detect required TUN, routing and interface-binding support read-only.
   - See [`amneziawg-runtime.md`](amneziawg-runtime.md) for the automated
     pre-router checks and the remaining live-router gate.

3. **Single AWG slot**
   - Store a validated AWG profile atomically with mode `0600`.
   - Start/stop the AWG interface with rollback on failed handshake or SOCKS
     health-check.
   - Reuse the existing local SOCKS5 address and Keenetic policy.

4. **Mixed failover**
   - Generalize primary/backup from VLESS sources to typed VPN profiles.
   - Support VLESS→AWG, AWG→VLESS and AWG→AWG.
   - Switch the selected adapter transactionally and roll back to the last
     healthy slot on failure.

5. **Agent and bot**
   - Add typed profile status without returning secrets.
   - Let the bot assign a guest `vpn://` link to primary or backup.
   - Add AWG-aware health, switch, diagnostics and deletion flows for FULL and
     MINIMAL agents.

6. **Bundles, live Dev validation and Latest**
   - Embed the AWG runtime in both installer editions only after the memory
     probe passes; otherwise make MINIMAL capability-based without reducing
     agent management.
   - Test one router through the `dev` channel, including forced failover and
     automatic rollback.
   - Promote the verified bot, agent and router bundles to `latest`.
   - Migrate every remaining agent to HTTPS, then disable legacy HTTP on the
     control server.

## Safety rules

- A full-access link is never needed on a router and must be rejected because
  it can contain VPS administration credentials.
- Config contents, private keys, preshared keys and complete `vpn://` links are
  never written to bot messages, routine logs, manifests or support output.
- Import and validation do not change the active slot. Apply always stages a
  new profile first and keeps the current healthy connection available for
  rollback.
