#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════
#  save-images.sh
#  [준비 서버에서 실행] Docker 이미지를 tar로 저장
#  Usage: bash scripts/save-images.sh
# ════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGES_DIR="$ROOT_DIR/images"

mkdir -p "$IMAGES_DIR"

declare -A IMAGES=(
  ["prometheus"]="prom/prometheus:latest"
  ["grafana"]="grafana/grafana:latest"
  ["node-exporter"]="prom/node-exporter:latest"
  ["cadvisor"]="gcr.io/cadvisor/cadvisor:latest"
  ["dcgm-exporter"]="nvcr.io/nvidia/k8s/dcgm-exporter:latest"
)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Docker 이미지 저장 시작"
echo " 저장 경로: $IMAGES_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for name in "${!IMAGES[@]}"; do
  image="${IMAGES[$name]}"
  output="$IMAGES_DIR/${name}.tar"

  echo ""
  echo "▶ [$name] $image → ${name}.tar"

  # 이미지 존재 확인
  if ! docker image inspect "$image" &>/dev/null; then
    echo "  ⚠ 이미지 없음: $image — pull 시도..."
    docker pull "$image"
  fi

  echo -n "  저장 중..."
  docker save "$image" -o "$output"
  size=$(du -sh "$output" | cut -f1)
  echo " 완료 ($size)"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 저장 완료 — 파일 목록:"
ls -lh "$IMAGES_DIR"
echo ""
echo " 다음 단계: 전체 디렉토리를 tar로 묶어 반입하세요"
echo "   cd $(dirname "$ROOT_DIR")"
echo "   tar -czf gpu_monitoring_bundle.tar.gz gpu_monitoring/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
