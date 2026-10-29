# T3 local integration evidence — 2026-10-28

Inspected the installed `/Applications/T3 Code (Nightly).app`, version `0.1.4-nightly.20261028.3824`, plus focused public upstream files through the GitHub connector. No repository download, T3 patch, database/session-content read or provider credential extraction was used.

## Authentication

The official existing launcher `~/.t3/bin/t3` executes the installed app's bundled CLI in Electron's Node mode. `t3 auth session issue --help` documents repeatable `--scope`, `--ttl`, `--label`, `--subject`, `--json`, and `--base-dir`. Both upstream `apps/server/src/cli/auth.ts` and the installed server bundle call `EnvironmentAuth.issueSession` and emit `{sessionId, token, method, scopes, expiresAt, …}`.

Each companion read:

1. Reads only `~/.t3/userdata/server-runtime.json` to discover the current local endpoint. Rejects non-loopback hosts, non-HTTP origins, mismatched ports, credentials/query/fragment/path in the origin and invalid port values.
2. Runs the existing CLI with arguments `auth session issue --scope orchestration:read --ttl 5m --label 'T3 Usage read-only' --subject t3-usage-menubar --json --base-dir ~/.t3 --log-level none`. There is no shell interpolation; the executable path, base directory and working directory are absolute.
3. Requires the returned method to be `bearer-access-token` and its only scope to be `orchestration:read`. The token remains in memory, is never passed as a process argument or printed, and is not persisted by this app. T3's supported auth control plane records the short-lived session itself.
4. Connects with `Authorization: Bearer …` to `ws://<loopback>:<port>/ws?orchestrationProtocol=2`. The installed `authenticateWebSocketUpgrade` accepts the normal bearer HTTP authentication path when no ticket is provided. A WebSocket ticket is not needed for this native client. Ephemeral URLSession has no cookie/credential storage, disables proxies for this loopback connection, and rejects redirects.
5. Closes the socket and invokes `auth session revoke <issued-session-id>` through the official CLI before returning, including after a read failure. Successful diagnosis includes `readSessionRevoked: true`. Failed revocation warns in the popover; the CLI-issued five-minute TTL bounds residual access on errors/crash/quit.

`orchestration:read` is the installed server's minimum permission for `subscribeServerConfig`, `server.getConfig` and `server.refreshProviders`; no quota-only permission exists in the inspected contract. The token technically grants that broader read permission, but this app invokes only the config subscription. It never calls thread/conversation, filesystem, terminal, secret, settings-write or provider-management RPCs. No fabricated JWTs, extracted existing desktop credentials, provider re-login or authentication changes are involved.

CLI issue/revoke each have a 10-second deadline plus bounded termination/drain. The WebSocket read has an 18-second deadline, 64-frame maximum and 16 MiB message bound. Error text is reduced to fixed local codes/messages; raw CLI stderr, server errors and config payloads are not logged or saved.

## Wire and snapshots

The installed Effect RPC transport uses JSON frames, not JSON-RPC 2.0. It requires orchestration protocol 2 in the WebSocket query. Send:

```json
{"_tag":"Request","id":"1","tag":"subscribeServerConfig","payload":{"usageLimitSources":true,"workspaceSnapshotsOnDemand":true},"headers":[]}
```

Receive `Chunk` messages with `requestId: "1"` and `values` containing events. Acknowledge each with `{"_tag":"Ack","requestId":"1"}`. A snapshot event contains `config.environment.environmentId` and `config.providers`. The opt-in `usageLimitSourcesUpdated` event contains `payload.sources` (including an empty array); the client waits for both, then disconnects. No long-lived stream/reconnection loop exists. `Ping` receives `Pong`; exit/defect/timeout fails closed.

Important installed behavior:

- `server.getConfig` reads cached providers but omits hub usage sources.
- `subscribeServerConfig` with `usageLimitSources: true` emits the current hub snapshots without invoking hub refresh. `workspaceSnapshotsOnDemand: true` avoids per-project provider snapshots.
- `providerRegistry.getProviders` reads its existing state reference.
- `server.refreshProviders` can refresh hubs, probe instances and, with `refreshModels`, rediscover models. The companion never calls it. Refresh and polling only reread existing snapshots. Automatic reads are at least five minutes apart, including failures. Explicit manual Refresh bypasses that interval while idle; reads never overlap and there is no automatic immediate retry loop.

Provider fields consumed: `instanceId`, `driver`, `displayName`, `auth.{profileId,email,label,workspaceId}`, and `usageLimits`. Provider selection identity hashes environment ID + individual instance ID + account anchor + workspace; a renamed display label alone does not switch identity. The opaque credential fingerprint is only a fallback identity anchor if no profile/email is exposed; it is never exported. If T3 supplies no account anchor, the instance is the available scope. This cannot detect an unreported account change inside that instance.

Hub fields consumed: source `id`, `label`, `accounts`, presence of `error`; each account's `id`, `driver`, `email`, `workspaceId`, `usageLimits`. Hub selection identity hashes environment + source + individual account + workspace. Equal providers across instances or hubs are never pooled. The live backend exposed zero hub sources, so hub behavior is fixture/core-test verified only.

Provider rows are included only when the contract `enabled` field is Boolean true; disabled, missing or malformed values are excluded. A disabled saved selection stays unavailable without switching accounts.

Quota fields consumed: `checkedAt`, `windows[{id,kind,label,usedPercent,resetsAt?,windowDurationMins?}]`, and `unavailable.reason`. `usedPercent` must be a finite non-Boolean number within 0…100. Malformed windows, duplicate IDs, malformed dates or malformed unavailable envelopes block a current quota display. Unsupported/failed snapshots do not become full quota. Unknown/missing windows are unavailable. Passed reset deadlines and future-clock anomalies cannot show a current number. Staleness is based on provider `checkedAt`, never the companion fetch time.

## Source pointers

Primary upstream links (current at inspection; installed behavior was separately checked):

- [CLI auth command](https://github.com/pingdotgg/t3code/blob/main/apps/server/src/cli/auth.ts)
- [Auth scopes/contracts](https://github.com/pingdotgg/t3code/blob/main/packages/contracts/src/auth.ts)
- [RPC names/payloads](https://github.com/pingdotgg/t3code/blob/main/packages/contracts/src/rpc.ts)
- [Provider and config contracts](https://github.com/pingdotgg/t3code/blob/main/packages/contracts/src/server.ts)
- [Usage window/account/source contracts](https://github.com/pingdotgg/t3code/blob/main/packages/contracts/src/providerUsageLimits.ts)
- [Installed route counterpart](https://github.com/pingdotgg/t3code/blob/main/apps/server/src/ws.ts)
- [Hub snapshot counterpart](https://github.com/pingdotgg/t3code/blob/main/apps/server/src/usage/UsageLimitSources.ts)

Installed evidence came from the ASAR header and only `apps/server/dist/binCli-AmpdMIrJ.mjs` (14,345,564 bytes), not a source checkout or user database. Relevant sections: `auth.ts`/`cliAuthFormat.ts`, `EnvironmentAuth`, `UsageLimitSources`, `rpc.ts`, `server.ts`, `providerUsageLimits.ts`, `ws.ts`, Effect `RpcSerialization`/`RpcClient`/`RpcServer`. A temporary extracted source copy was used solely to inspect these interfaces; it is excluded from the app package. The app itself reads no ASAR files.

Installed inspected bundle SHA-256: `d4eb44c0b131a1fa54c8199c8c3bc1ad1a861c6e88796d67beb97882efff8050`. The generated extraction was removed after recording this evidence; the original installed ASAR is unchanged.
