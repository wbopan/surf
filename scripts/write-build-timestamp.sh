#!/bin/bash
# Prebuild phase: stamp build time into app resources so the Dev UI can show
# exactly which build is running (Debug builds only matter, but stamping
# unconditionally is harmless).
set -euo pipefail
cd "$(dirname "$0")/.."
date "+%Y-%m-%d %H:%M:%S" > DSHarness/Resources/BuildTimestamp.txt
