#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════
#  deploy.sh
#  [GPU 서버에서 실행] 이미지 로드 → 스택 구동 → 상태 확인
#  Usage: bash scripts/deploy.sh [--load-only | --up-only | --status]
# ════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGES_DIR="$ROOT_DIR/images"
COMPOSE_DIR="$ROOT_DIR/compose"

MODE="${1:-all}"  # all | --load-only | --up-only | --status

print_section() { echo ""; echo "━━━ $1 ━━━"; }
ok()  { echo "  ✅ $*"; }
warn(){ echo "  ⚠️  $*"; }
err() { echo "  ❌ $*"; }

# ── 1. 이미지 로드 ──────────────────────────────────────────
load_images() {
  print_section "Docker 이미지 로드"

  if [ ! -d "$IMAGES_DIR" ]; then
    err "images/ 디렉토리가 없습니다: $IMAGES_DIR"
    exit 1
  fi

  tar_files=("$IMAGES_DIR"/*.tar)
  if [ ${#tar_files[@]} -eq 0 ] || [ ! -f "${tar_files[0]}" ]; then
    err "images/ 디렉토리에 .tar 파일이 없습니다."
    exit 1
  fi

  for tar_file in "${tar_files[@]}"; do
    name=$(basename "$tar_file" .tar)
    echo -n "  ▶ $name 로드 중..."
    docker load -i "$tar_file" 2>&1 | grep -E "Loaded|already" | sed 's/^/    /' || true
    ok "$name 로드 완료"
  done

  echo ""
  echo "  로드된 이미지 목록:"
  docker images --filter=reference="prom/*" \
                --filter=reference="grafana/*" \
                --filter=reference="gcr.io/cadvisor/*" \
                --filter=reference="nvcr.io/nvidia/*" \
                --format "  {{.Repository}}:{{.Tag}}\t{{.Size}}" 2>/dev/null || docker images
}

# ── 2. 사전 점검 ────────────────────────────────────────────
preflight_check() {
  print_section "사전 점검"

  # .env 파일 확인
  if [ ! -f "$COMPOSE_DIR/.env" ]; then
    err ".env 파일 없음: $COMPOSE_DIR/.env"
    exit 1
  fi
  ok ".env 파일 확인"

  # nvidia-smi 확인
  if command -v nvidia-smi &>/dev/null; then
    ok "nvidia-smi 감지됨"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null \
      | awk '{print "    GPU: " $0}' || true
  else
    warn "nvidia-smi 없음 → DCGM Exporter가 실패할 수 있습니다"
    warn "nvidia-container-toolkit이 설치되어 있는지 확인하세요"
  fi

  # 포트 충돌 확인
  source "$COMPOSE_DIR/.env" 2>/dev/null || true
  for port in "${PROMETHEUS_PORT:-9090}" "${GRAFANA_PORT:-3000}" "${CADVISOR_PORT:-8080}" "${NODE_EXPORTER_PORT:-9100}" "${DCGM_EXPORTER_PORT:-9400}"; do
    if ss -tlnp 2>/dev/null | grep -q ":$port "; then
      warn "포트 $port 이미 사용 중 — .env 에서 포트를 변경하세요"
    else
      ok "포트 $port 사용 가능"
    fi
  done
}

# ── 3. 스택 구동 ────────────────────────────────────────────
start_stack() {
  print_section "Docker Compose 스택 구동"

  cd "$COMPOSE_DIR"
  docker compose --env-file .env up -d --remove-orphans
  ok "컨테이너 구동 완료"
}

# ── 4. 상태 확인 ────────────────────────────────────────────
check_status() {
  print_section "구동 상태 확인"

  cd "$COMPOSE_DIR"
  echo "  [컨테이너 상태]"
  docker compose ps

  echo ""
  echo "  [Exporter 메트릭 응답 확인]"
  source .env 2>/dev/null || true

  sleep 5  # 컨테이너 초기화 대기

  check_endpoint() {
    local name=$1 url=$2
    if curl -sf "$url" --max-time 5 &>/dev/null; then
      ok "$name 응답 정상: $url"
    else
      warn "$name 응답 없음: $url (아직 초기화 중일 수 있습니다)"
    fi
  }

  check_endpoint "Node Exporter"  "http://localhost:${NODE_EXPORTER_PORT:-9100}/metrics"
  check_endpoint "cAdvisor"       "http://localhost:${CADVISOR_PORT:-8080}/metrics"
  check_endpoint "DCGM Exporter"  "http://localhost:${DCGM_EXPORTER_PORT:-9400}/metrics"
  check_endpoint "Prometheus"     "http://localhost:${PROMETHEUS_PORT:-9090}/-/healthy"
  check_endpoint "Grafana"        "http://localhost:${GRAFANA_PORT:-3000}/api/health"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " 🎉 배포 완료!"
  echo ""
  echo "  Grafana 대시보드 접속:"
  echo "  http://$(hostname -I | awk '{print $1}'):${GRAFANA_PORT:-3000}"
  echo "  계정: ${GF_ADMIN_USER:-admin} / ${GF_ADMIN_PASSWORD:-admin123}"
  echo ""
  echo "  Prometheus 접속:"
  echo "  http://$(hostname -I | awk '{print $1}'):${PROMETHEUS_PORT:-9090}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── 메인 ────────────────────────────────────────────────────
case "$MODE" in
  --load-only)
    load_images
    ;;
  --up-only)
    preflight_check
    start_stack
    check_status
    ;;
  --status)
    check_status
    ;;
  all|*)
    load_images
    preflight_check
    start_stack
    check_status
    ;;
esac
