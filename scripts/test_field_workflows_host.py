"""Foundation/CryptoKit tests of field formats; no device, UI or user files."""
from pathlib import Path
import argparse
import json
import os
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--coverage-dir', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
sources = sorted((root / 'Sources/Features/FieldWorkflows').glob('*.swift'))
sources = [p for p in sources if not p.name.endswith('View.swift') and p.name in {
    'FieldWire.swift', 'FieldEvidence.swift', 'PortableObject.swift', 'SubGhzProfile.swift',
    'VerifiedUserFiles.swift',
    'FieldEvidenceRepository.swift',
}]
sources.append(root / 'Sources/FlipperKit/Storage/FlipperFile.swift')
gate = root / 'Sources/FlipperKit/Storage/DeviceFileMutationGate.swift'
if gate.exists(): sources.append(gate)
with tempfile.TemporaryDirectory(prefix='tumo-field-workflows-') as directory:
    binary = Path(directory) / 'field-workflows'
    flags = ['-profile-generate', '-profile-coverage-mapping'] if args.coverage_dir else []
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-Onone', *flags,
                    *map(str, sources), str(root / 'scripts/fixtures/field_workflows/main.swift'),
                    '-o', str(binary)], check=True, timeout=120)
    profile = Path(directory) / 'coverage.profraw'
    subprocess.run([str(binary)], env=dict(os.environ, LLVM_PROFILE_FILE=str(profile)), check=True, timeout=60)
    if args.coverage_dir:
        output = args.coverage_dir.resolve()
        output.mkdir(parents=True, exist_ok=True)
        merged = Path(directory) / 'coverage.profdata'
        subprocess.run(['xcrun', 'llvm-profdata', 'merge', '-sparse', str(profile), '-o', str(merged)], check=True)
        report = json.loads(subprocess.check_output(['xcrun', 'llvm-cov', 'export', str(binary),
                            '-instr-profile='+str(merged)], text=True))
        selected = [file for file in report['data'][0]['files'] if file['filename'] in map(str,sources)]
        lines = sum(file['summary']['lines']['count'] for file in selected)
        covered = sum(file['summary']['lines']['covered'] for file in selected)
        summary = {Path(file['filename']).name: file['summary'] for file in selected}
        summary['scope'] = 'actual Foundation field models, checked write service, repository and mutation gate; excludes UI and fixture'
        summary['linePercent'] = covered*100/lines
        (output / 'coverage.json').write_text(json.dumps(summary, indent=2)+'\n')
        print(f'Production field logic line coverage: {covered}/{lines} = {covered*100/lines:.2f}%')
        assert covered/lines >= .8, 'Field logic coverage below 80%'
