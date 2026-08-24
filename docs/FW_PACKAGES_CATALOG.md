# FW Packages catalog behavior

TumoCompanion treats FW Packages as an independent overlay catalog. The
firmware version is used only to infer the stable/dev channel and the device
API/target used for compatibility; it is not the package catalog identity.

At refresh the app reads the immutable `catalog-index.json`, then resolves the
selected tag's manifest and archive from GitHub. Auto mode chooses the highest
compatible active revision. The revision picker exposes the complete compatible
history, including migrated legacy revisions, and a selected older revision is
rechecked by tag immediately before installation.

Installation remains the existing staged, hash-verified, atomic transaction. A
rollback therefore cannot overwrite an unrelated firmware-owned file. A future
catalog generator must include reversible cleanup entries for targets removed
from an overlay snapshot; those paths are moved into the transaction rollback
area rather than deleted directly.

The catalog index is advisory for discovery and withdrawal state. Manifest,
archive, package target and device identity checks remain authoritative, so an
index edit or a replaced GitHub asset cannot make an incompatible package
installable.
