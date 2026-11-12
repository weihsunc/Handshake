#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
qa_dir=$(mktemp -d)
trap 'rm -rf "$qa_dir"' EXIT
xcrun swiftc -module-cache-path "$qa_dir/modules" Handshake/SignatureFields.swift Handshake/SignatureSlots.swift Tests/BlankFieldsRegression.swift -o "$qa_dir/blank-fields"
"$qa_dir/blank-fields"
