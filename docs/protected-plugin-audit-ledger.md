# Protected Community App audit ledger

TumoCompanion never lets a phone owner dismiss a protected-app difference. The
accepted baseline is produced by the Tumoflip upstream-audit automation and read from:

`https://raw.githubusercontent.com/squazaryu/tumoflip/protected-app-audit-ledger/latest.json`

The bundled `Resources/ProtectedPluginAuditLedger.json` is only an offline bootstrap
for the exact `9aug2026` archives. Updating that file is not the normal delivery path
and does not require a TumoCompanion release for later Community Packs.

## Contract

An audit matches only when all of these values match exactly:

1. all-the-plugins release tag;
2. SHA-256 of both `all-the-apps-base.zip` and `all-the-apps-extra.zip`;
3. protected binary source path;
4. resolved Tumoflip destination path;
5. MD5 of the binary contained in the source archive.

The accepted dispositions are:

- `auditedDifference`: a present Tumoflip protected binary is expected to differ;
- `intentionallyReplaced`: this exact upstream binary is expected to be absent because
  the audit names a replacement. This is the only disposition allowed to cover a missing
  target.

Unknown device state, missing ordinary targets, incompatible FAP metadata, an unseen
pack, changed bytes or routes, and malformed authoritative JSON all fail closed as
`Needs review`. If the raw endpoint is temporarily unavailable, a previously validated
cache record is reused only for its exact tag and two archive hashes. A reachable but
malformed ledger never falls back to cache.

The bundled `9aug2026` bootstrap intentionally omits Sub-GHz RAW Edit. Issue `#281`
still requires FW Packages publication, physical-device acceptance, and issue closure;
until every gate is complete the exact RAW Edit binary must continue to appear as
`DIFF`, even though the remaining protected artifacts in that pack are covered.

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
