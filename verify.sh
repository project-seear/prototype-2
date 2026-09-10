#!/bin/bash
# Measured validation of the geometry and the HRTF renderer. No hardware needed.
# Exits non-zero if any check fails.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product verify
exec .build/release/verify
