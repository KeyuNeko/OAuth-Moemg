#!/usr/bin/env bash
# Check the latest versioned GitHub release without changing the running service.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "未配置 GitHub origin；请先将项目克隆到服务器。" >&2
  exit 1
fi

latest="$(git ls-remote --tags --refs origin 'v*' | awk '{sub("refs/tags/", "", $2); if ($2 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) print $2}' | sort -V | tail -n 1)"
if [[ -z "$latest" ]]; then
  echo "GitHub 尚无 vX.Y.Z 格式的发布标签。"
  exit 0
fi

current="$(git describe --tags --exact-match 2>/dev/null || true)"
if [[ -z "$current" ]]; then
  current="$(git rev-parse --short HEAD)"
fi

echo "当前版本：$current"
echo "最新发布：$latest"
if [[ "$current" == "$latest" ]]; then
  echo "已是最新版本。"
else
  echo "可更新。请在宝塔计划任务中点击执行 bash scripts/update.sh。"
fi
