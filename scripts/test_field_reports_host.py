#!/usr/bin/env python3
"""Run the production field-report parser without BLE, UIKit or user files."""
import os
import json
import sys
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = [root / "Sources/Features/FieldReports/FieldReport.swift"]
environment = dict(os.environ)
if "DEVELOPER_DIR" not in environment and Path("/Applications/Xcode.app/Contents/Developer").is_dir():
    environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
with tempfile.TemporaryDirectory(prefix="tumo-field-reports-") as directory:
    work = Path(directory)
    flags = ["-profile-generate", "-profile-coverage-mapping"] if "--coverage" in sys.argv else []
    binary = work / "parser"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-Onone", *flags,
        *[str(path) for path in sources if path.exists()],
        str(root / "scripts/fixtures/field_reports/main.swift"), "-o", str(binary),
    ], check=True, timeout=120, env=environment)
    subprocess.run([str(binary)], check=True, timeout=15, env={**environment, "LLVM_PROFILE_FILE": str(work / "parser.profraw")})
    repository = root / "Sources/Features/FieldReports/FieldReportRepository.swift"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-Onone", *flags,
        *[str(path) for path in sources if path.exists()],
        *([str(repository)] if repository.exists() else []),
        *([str(root / "Sources/FlipperKit/Storage/FlipperFile.swift")] if (root / "Sources/FlipperKit/Storage/FlipperFile.swift").exists() else []),
        str(root / "scripts/fixtures/field_report_loading/main.swift"), "-o", str(work / "loader"),
    ], check=True, timeout=120, env=environment)
    subprocess.run([str(work / "loader")], check=True, timeout=15, env={**environment, "LLVM_PROFILE_FILE": str(work / "loader.profraw")})
    if flags:
        subprocess.run(["xcrun", "llvm-profdata", "merge", "-sparse", str(work / "parser.profraw"), str(work / "loader.profraw"), "-o", str(work / "coverage.profdata")], check=True, env=environment)
        result = subprocess.check_output(["xcrun", "llvm-cov", "export", str(binary), "-object", str(work / "loader"), "-instr-profile=" + str(work / "coverage.profdata")], text=True, env=environment)
        for item in json.loads(result)["data"][0]["files"]:
            if "/Sources/Features/FieldReports/" in item["filename"]:
                summary = item["summary"]
                print(Path(item["filename"]).name, "lines", round(summary["lines"]["percent"], 2), "regions", round(summary["regions"]["percent"], 2))
                if summary["lines"]["percent"] < 80:
                    raise SystemExit("Field report logic line coverage is below 80%")
