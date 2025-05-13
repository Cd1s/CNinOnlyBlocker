#!/bin/bash
set -e

echo "📥 克隆并执行 CNinOnlyBlocker"
cd "$(dirname "$0")"

chmod +x blocker.sh
./blocker.sh
