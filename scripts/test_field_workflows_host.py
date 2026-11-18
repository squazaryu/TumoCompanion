"""Foundation/CryptoKit tests of field formats; no device, UI or user files."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = sorted((root / 'Sources/Features/FieldWorkflows').glob('*.swift'))
sources = [p for p in sources if not p.name.endswith('View.swift') and p.name in {
    'FieldWire.swift', 'FieldEvidence.swift', 'PortableObject.swift', 'SubGhzProfile.swift',
    'VerifiedUserFiles.swift',
}]
with tempfile.TemporaryDirectory(prefix='tumo-field-workflows-') as directory:
    binary = Path(directory) / 'field-workflows'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-Onone',
                    *map(str, sources), str(root / 'scripts/fixtures/field_workflows/main.swift'),
                    '-o', str(binary)], check=True, timeout=120)
    subprocess.run([str(binary)], check=True, timeout=60)
