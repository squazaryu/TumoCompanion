# Protected Community App audit ledger

TumoCompanion never lets a phone owner dismiss a protected-app difference. The
accepted baseline is produced by the Tumoflip upstream-audit automation and read from:

`https://raw.githubusercontent.com/squazaryu/tumoflip-fw-packages/protected-app-audit-ledger/latest.json`

During repository migration, transport failures and HTTP 404 may fall back to the
legacy `squazaryu/tumoflip` endpoint. Other HTTP failures and malformed primary
bytes are terminal for that refresh; they never silently select legacy data.

The bundled `Resources/ProtectedPluginAuditLedger.json` is only an offline bootstrap
for the exact `9aug2026` archives. Updating that file is not the normal delivery path
and does not require a TumoCompanion release for later Community Packs.

## Contract

An audit matches only when all of these values match exactly:

1. all-the-plugins release tag;
2. SHA-256 of both `all-the-apps-base.zip` and `all-the-apps-extra.zip`;
3. protected binary source path;
4. resolved Tumoflip destination path;
5. MD5 of the binary contained in the source archive;
6. the current on-device MD5 as an exact member of `targetMD5s`;
7. at least one immutable target provenance tuple
   (`channel`, `releaseTag`, `manifestSHA256`) for every accepted target MD5.

The accepted dispositions are:

- `auditedDifference`: a present Tumoflip protected binary is expected to differ,
  but only one of the exact audited target MD5s is accepted;
- `sourceMatches`: the audit explicitly accepts the upstream source bytes at the
  Tumoflip target. Local byte equality without this ledger record remains `DIFF`;
- `intentionallyReplaced`: this exact upstream binary is expected to be absent because
  the audit names a replacement. This is the only disposition allowed to cover a missing
  target.

Unknown device state, missing ordinary targets, an arbitrary non-nil target MD5,
incompatible FAP metadata, an unseen pack, changed bytes or routes, and malformed authoritative JSON all fail closed as
`Needs review`. If the raw endpoint is temporarily unavailable, a previously validated
cache record is reused only for its exact tag and two archive hashes. A reachable but
malformed ledger never falls back to cache.

The bundled `9aug2026` bootstrap is tracked by canonical audit issue `#302` and accepts
only nine artifacts: eight FAP targets attested by the immutable
`fw-packages-stable-001` / `fw-packages-dev-003` manifests plus the intentionally
replaced Claude Remote. It intentionally omits Sub-GHz RAW Edit and all 14 TOTP FALs.
RAW Edit still requires FW Packages publication, physical-device acceptance, and issue
`#281` closure; the FALs require publication in a manifest that includes their exact
target bytes. These 15 unresolved artifacts must continue to appear as `DIFF`.

Offline cache acceptance is deliberately scoped to the exact pack identity but is not
time-bounded. Before the app has observed a newer authoritative decision, the last exact
validated record remains usable while the raw endpoint is unreachable. The cache records
which endpoint accepted it: a legacy record may bootstrap a fresh install, but after a
reachable primary accepts that exact pack, the positive primary authority is sticky across
outages and app launches. TumoCompanion reuses that cached primary record without querying
or accepting a possibly divergent legacy ledger; only another reachable primary response
may replace it. Once a reachable, valid primary `latest.json` omits that exact pack identity,
TumoCompanion persists an
exact-pack, source-aware negative tombstone and removes its positive cache. The primary
tombstone blocks cache, bundled bootstrap, and an exact legacy fallback while the primary
is unavailable; only a later reachable, valid primary ledger containing the exact audit
clears it. Legacy remains usable as a bootstrap only before the primary has made an
authoritative decision for that pack. A revocation still cannot propagate to a phone that
never reaches the updated raw endpoint, so we do not claim immediate offline revocation.

## Automation update sequence

For every new Community Pack the automation must:

1. download both release archives and verify their published digests;
2. open/reconcile the canonical audit issue;
3. enumerate every protected FAP/FAL after applying the same Tumoflip route mapping;
4. compare source history and record a port, explicit rejection, replacement, or no-change
   decision with changelog and FW Packages provenance;
5. leave the issue and ledger unresolved while any protected source change is undecided;
6. after all decisions are complete, publish an immutable history record and atomically
   update `latest.json`, retaining prior audits so pinned release tags remain usable;
7. close the canonical issue only after the published ledger re-validates against both ZIPs.

The iOS consumer intentionally ignores descriptive extra fields, but the operational
fields in the bundled schema are mandatory. Removing an accepted audit from the live
ledger is a revocation and must be published as a valid unresolved/tombstone record;
deleting or corrupting the endpoint is not a safe revocation mechanism.
