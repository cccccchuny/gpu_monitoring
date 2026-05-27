# GPU 서버 모니터링 구축 계획

> **대상 환경**: Airgap GPU 서버 (인터넷 차단, Docker만 설치)  
> **작성일**: 2026-05-27  
> **기준 환경**: 현재 서버(준비 서버)에서 이미지 및 설정 패키징 → USB/파일 전송 → GPU 서버 배포

---

## 1. 아키텍처 개요

```
[GPU 서버 - Airgap]
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  ┌──────────────┐   scrape   ┌─────────────────────────┐   │
│  │  Prometheus  │◄──────────┤  node-exporter (:9100)   │   │
│  │   (:9090)    │           │  (CPU/Mem/Disk/Network)  │   │
│  │              │◄──────────┤  cadvisor (:8080)        │   │
│  │              │           │  (Container 메트릭)       │   │
│  │              │◄──────────┤  dcgm-exporter (:9400)   │   │
│  │              │           │  (GPU 메트릭)             │   │
│  └──────┬───────┘           └─────────────────────────┘   │
│         │ datasource                                        │
│  ┌──────▼───────┐                                          │
│  │   Grafana    │  ← 대시보드 3종 import                   │
│  │   (:3000)    │                                          │
│  └──────────────┘                                          │
│                                                             │
│  [서비스 컨테이너들]                                         │
│   kird_ai_service, kird_ai_service_prod_a/b ...            │
└─────────────────────────────────────────────────────────────┘
```

### 컴포넌트 역할

| 컴포넌트 | 이미지 | 포트 | 역할 |
|---|---|---|---|
| Prometheus | `prom/prometheus:latest` | 9090 | 메트릭 수집·저장 (15일 보존) |
| Grafana | `grafana/grafana:latest` | 3000 | 시각화 대시보드 |
| Node Exporter | `prom/node-exporter:latest` | 9100 | 호스트 리소스 (CPU/Mem/Disk/Net) |
| cAdvisor | `gcr.io/cadvisor/cadvisor:latest` | 8080 | 컨테이너별 리소스 메트릭 |
| DCGM Exporter | `nvcr.io/nvidia/k8s/dcgm-exporter:latest` | 9400 | NVIDIA GPU 메트릭 |

---

## 2. 준비 서버 작업 (현재 서버)

### 2-1. 디렉토리 구조 생성

```
gpu_monitoring/
├── plan.md                          # 본 문서
├── images/                          # Docker 이미지 tar 파일
│   ├── prometheus.tar
│   ├── grafana.tar
│   ├── node-exporter.tar
│   ├── cadvisor.tar
│   └── dcgm-exporter.tar
├── compose/                         # GPU 서버 배포용 파일
│   ├── docker-compose.yml
│   └── .env                         # 환경변수 (포트, 디스크 경로 등)
├── prometheus/
│   └── prometheus.yml               # Prometheus 스크레이프 설정
└── grafana/
    ├── provisioning/
    │   ├── datasources/
    │   │   └── prometheus.yml       # Grafana Datasource 자동 프로비저닝
    │   └── dashboards/
    │       └── dashboards.yml       # 대시보드 자동 로드 설정
    └── dashboards/
        ├── 01-container-list.json   # 대시보드 ①: 컨테이너 목록
        ├── 02-host-resources.json   # 대시보드 ②: 서버 리소스
        └── 03-gpu-resources.json    # 대시보드 ③: GPU 리소스
```

### 2-2. Docker 이미지 저장 (tar export)

현재 서버에 이미 pull된 이미지들을 tar로 저장:

```bash
cd /home/ned/claude/gpu_monitoring

# images 디렉토리에 저장
docker save prom/prometheus:latest        -o images/prometheus.tar
docker save grafana/grafana:latest        -o images/grafana.tar
docker save prom/node-exporter:latest     -o images/node-exporter.tar
docker save gcr.io/cadvisor/cadvisor:latest -o images/cadvisor.tar
docker save nvcr.io/nvidia/k8s/dcgm-exporter:latest -o images/dcgm-exporter.tar

# 저장 확인
ls -lh images/
```

> **참고**: `nvcr.io/nvidia/k8s/dcgm-exporter:latest` 이미지는 현재 서버에 이미 pull됨 (884MB)

---

## 3. 설정 파일 상세

### 3-1. `.env` (환경변수 파일)

GPU 서버 환경에 맞게 수정하는 단일 진입점:

```env
# ── 포트 설정 ──────────────────────────
PROMETHEUS_PORT=9090
GRAFANA_PORT=3000
CADVISOR_PORT=8080
NODE_EXPORTER_PORT=9100
DCGM_EXPORTER_PORT=9400

# ── Grafana 계정 ───────────────────────
GF_ADMIN_USER=admin
GF_ADMIN_PASSWORD=admin123

# ── 디스크 모니터링 대상 경로 ───────────
# node-exporter가 수집할 파티션 (쉼표 구분, 정규식 가능)
# GPU 서버에서 위협이 되는 파티션 경로로 수정할 것
# 예시: /, /data, /mnt/storage, /var/lib/docker
DISK_MONITOR_PATHS=/,/data,/mnt

# ── Prometheus 데이터 보존 기간 ────────
PROMETHEUS_RETENTION=15d
```

### 3-2. `docker-compose.yml`

```yaml
version: '3.8'

networks:
  monitoring:
    driver: bridge

volumes:
  prometheus_data:
  grafana_data:

services:
  # ── Prometheus ─────────────────────────────────────────────
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "${PROMETHEUS_PORT:-9090}:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=${PROMETHEUS_RETENTION:-15d}'
      - '--web.enable-lifecycle'
    networks:
      - monitoring

  # ── Grafana ────────────────────────────────────────────────
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - "${GRAFANA_PORT:-3000}:3000"
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
    environment:
      - GF_SECURITY_ADMIN_USER=${GF_ADMIN_USER:-admin}
      - GF_SECURITY_ADMIN_PASSWORD=${GF_ADMIN_PASSWORD:-admin123}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/01-container-list.json
    networks:
      - monitoring
    depends_on:
      - prometheus

  # ── Node Exporter ──────────────────────────────────────────
  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: unless-stopped
    ports:
      - "${NODE_EXPORTER_PORT:-9100}:9100"
    volumes:
      - /:/host:ro,rslave
    command:
      - '--path.rootfs=/host'
      # 불필요한 tmpfs/overlay 제외, 실제 파티션만 수집
      - '--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run|var/lib/docker/.+|host/run|host/proc|host/sys)($$|/)'
      - '--collector.filesystem.fs-types-exclude=^(tmpfs|overlay|squashfs|nsfs)$$'
    networks:
      - monitoring
    pid: host

  # ── cAdvisor ───────────────────────────────────────────────
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    restart: unless-stopped
    ports:
      - "${CADVISOR_PORT:-8080}:8080"
    volumes:
      - /:/rootfs:ro,rslave
      - /sys:/sys:ro
      - /var/lib/docker:/var/lib/docker:ro,rslave
      - /var/run:/var/run:rw
    privileged: true
    networks:
      - monitoring

  # ── DCGM Exporter (GPU 메트릭) ─────────────────────────────
  dcgm-exporter:
    image: nvcr.io/nvidia/k8s/dcgm-exporter:latest
    container_name: dcgm-exporter
    restart: unless-stopped
    ports:
      - "${DCGM_EXPORTER_PORT:-9400}:9400"
    environment:
      - DCGM_EXPORTER_LISTEN=:9400
      - DCGM_EXPORTER_INTERVAL=5000   # 5초 수집 간격
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    cap_add:
      - SYS_ADMIN
    networks:
      - monitoring
```

### 3-3. `prometheus/prometheus.yml`

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["prometheus:9090"]

  - job_name: "node-exporter"
    static_configs:
      - targets: ["node-exporter:9100"]

  - job_name: "cadvisor"
    scrape_interval: 10s          # 컨테이너 메트릭은 더 빠르게
    static_configs:
      - targets: ["cadvisor:8080"]

  - job_name: "dcgm-exporter"
    scrape_interval: 10s          # GPU 메트릭도 빠르게
    static_configs:
      - targets: ["dcgm-exporter:9400"]
```

### 3-4. Grafana Provisioning

**`grafana/provisioning/datasources/prometheus.yml`**
```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
```

**`grafana/provisioning/dashboards/dashboards.yml`**
```yaml
apiVersion: 1
providers:
  - name: 'GPU Monitoring'
    orgId: 1
    folder: 'GPU Server'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
```

---

## 4. Grafana 대시보드 설계

### 대시보드 ① `01-container-list.json` — 실행 중인 컨테이너 목록

**목적**: 현재 실행 중인 컨테이너 현황을 한눈에 파악, 이름으로 필터링

**Variable 설정**:
- `container_name`: `label_values(container_last_seen, name)` — 컨테이너명 멀티셀렉트

**패널 구성**:
| 패널 | 타입 | 쿼리 | 설명 |
|---|---|---|---|
| 실행 중인 컨테이너 수 | Stat | `count(container_last_seen{name=~"$container_name", name!=""})` | 현재 실행 수 |
| 컨테이너 상태 테이블 | Table | `container_last_seen{name=~"$container_name", name!=""}` | 이름/이미지/상태/업타임 |
| 컨테이너 CPU 사용률 | Time series | `rate(container_cpu_usage_seconds_total{name=~"$container_name"}[2m]) * 100` | 컨테이너별 CPU % |
| 컨테이너 메모리 사용량 | Time series | `container_memory_working_set_bytes{name=~"$container_name"}` | 컨테이너별 메모리 |
| 컨테이너 네트워크 I/O | Time series | `rate(container_network_receive_bytes_total{name=~"$container_name"}[2m])` | 수신/송신 바이트 |

---

### 대시보드 ② `02-host-resources.json` — GPU 서버 리소스

**목적**: 호스트 서버의 CPU·메모리·네트워크·디스크 전반 모니터링

**Variable 설정**:
- `disk_device`: `label_values(node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}, mountpoint)` — 디스크 경로 선택 (멀티셀렉트, 기본값: `.env`의 `DISK_MONITOR_PATHS` 경로들)
- `network_interface`: `label_values(node_network_info, device)` — 네트워크 인터페이스 선택

**패널 구성**:
| 패널 | 타입 | 쿼리 | 설명 |
|---|---|---|---|
| CPU 사용률 (%) | Gauge + Time series | `100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100)` | 전체 CPU 평균 |
| CPU 코어별 사용률 | Heatmap | `rate(node_cpu_seconds_total{mode!="idle"}[2m])` | 코어별 열지도 |
| 메모리 사용 현황 | Stat + Bar gauge | `(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100` | 사용률 % |
| 메모리 상세 | Time series | MemTotal/MemFree/Cached/Buffers | 메모리 세부 분류 |
| 디스크 사용률 | Bar gauge | `(node_filesystem_size_bytes{mountpoint=~"$disk_device"} - node_filesystem_avail_bytes{mountpoint=~"$disk_device"}) / node_filesystem_size_bytes{mountpoint=~"$disk_device"} * 100` | **경로 커스텀 가능** |
| 디스크 I/O | Time series | `rate(node_disk_read_bytes_total[2m])` / `rate(node_disk_written_bytes_total[2m])` | 읽기/쓰기 처리량 |
| 네트워크 I/O | Time series | `rate(node_network_receive_bytes_total{device=~"$network_interface"}[2m])` | 수신/송신 bps |
| 시스템 부하 | Time series | `node_load1`, `node_load5`, `node_load15` | Load Average |

> **⚠️ 디스크 위협 경로 모니터링**: `disk_device` 변수에서 모니터링할 파티션을 체크박스로 선택 가능. 임계값(예: 80% 사용 시 주황, 90% 시 빨강)으로 경보 표시.

---

### 대시보드 ③ `03-gpu-resources.json` — GPU 리소스

**목적**: NVIDIA GPU 온도·VRAM·사용률 등 GPU 상태 전반 모니터링

**Variable 설정**:
- `gpu`: `label_values(DCGM_FI_DEV_GPU_TEMP, gpu)` — GPU 번호 선택 (멀티셀렉트)

**패널 구성**:
| 패널 | 타입 | 메트릭 | 설명 |
|---|---|---|---|
| GPU 온도 | Gauge | `DCGM_FI_DEV_GPU_TEMP{gpu=~"$gpu"}` | °C (임계값: 80°C 주황, 90°C 빨강) |
| GPU 온도 추이 | Time series | `DCGM_FI_DEV_GPU_TEMP` | GPU별 시계열 |
| GPU 사용률 (%) | Gauge | `DCGM_FI_DEV_GPU_UTIL{gpu=~"$gpu"}` | Compute 사용률 |
| GPU 사용률 추이 | Time series | `DCGM_FI_DEV_GPU_UTIL` | GPU별 시계열 |
| VRAM 사용량 | Bar gauge | `DCGM_FI_DEV_FB_USED{gpu=~"$gpu"}` | MiB 단위 |
| VRAM 사용률 (%) | Gauge | `DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) * 100` | % 사용률 |
| VRAM 추이 | Time series | `DCGM_FI_DEV_FB_USED` / `DCGM_FI_DEV_FB_FREE` | 사용/여유 |
| 전력 소비 | Gauge + Time series | `DCGM_FI_DEV_POWER_USAGE{gpu=~"$gpu"}` | Watt |
| SM Clock | Time series | `DCGM_FI_DEV_SM_CLOCK` | MHz |
| Memory Clock | Time series | `DCGM_FI_DEV_MEM_CLOCK` | MHz |
| PCIe 처리량 | Time series | `DCGM_FI_DEV_PCIE_TX_THROUGHPUT` / `DCGM_FI_DEV_PCIE_RX_THROUGHPUT` | MB/s |

---

## 5. GPU 서버 배포 절차

### 5-1. 파일 전송 (준비 서버 → GPU 서버)

```bash
# 준비 서버에서: 전체 디렉토리를 tar로 묶어 전송
cd /home/ned/claude
tar -czf gpu_monitoring_bundle.tar.gz gpu_monitoring/
# → USB 또는 내부망 scp/sftp로 전송
```

### 5-2. GPU 서버에서: 이미지 로드

```bash
cd gpu_monitoring

# 이미지 tar를 Docker에 로드
docker load -i images/prometheus.tar
docker load -i images/grafana.tar
docker load -i images/node-exporter.tar
docker load -i images/cadvisor.tar
docker load -i images/dcgm-exporter.tar

# 로드 확인
docker images
```

### 5-3. GPU 서버에서: 환경변수 설정

`.env` 파일에서 GPU 서버 환경에 맞게 수정:
```bash
vi compose/.env

# 반드시 확인할 항목:
# DISK_MONITOR_PATHS → GPU 서버의 실제 마운트 경로 (df -h 결과 참고)
# GF_ADMIN_PASSWORD  → 보안을 위해 변경 권장
```

### 5-4. GPU 서버에서: 스택 구동

```bash
cd compose
docker compose --env-file .env up -d

# 상태 확인
docker compose ps
docker compose logs -f
```

### 5-5. GPU 서버에서: 동작 확인

```bash
# 각 Exporter 메트릭 확인
curl http://localhost:9100/metrics | grep node_cpu       # Node Exporter
curl http://localhost:8080/metrics | grep container_     # cAdvisor
curl http://localhost:9400/metrics | grep DCGM_          # DCGM Exporter
curl http://localhost:9090/targets                        # Prometheus 스크레이프 상태

# Grafana 접속
# http://<GPU서버IP>:3000 → admin / (설정한 비밀번호)
```

---

## 6. 체크리스트

### 준비 서버 (현재 서버)
- [ ] `images/` 디렉토리에 5개 이미지 tar 저장 완료
- [ ] `compose/docker-compose.yml` 작성 완료
- [ ] `compose/.env` 작성 완료
- [ ] `prometheus/prometheus.yml` 작성 완료
- [ ] `grafana/provisioning/` 설정 파일 작성 완료
- [ ] `grafana/dashboards/` 대시보드 JSON 3종 생성 완료
- [ ] 전체 번들 tar.gz 패키징 완료

### GPU 서버
- [ ] NVIDIA 드라이버 설치 확인 (`nvidia-smi` 동작 확인)
- [ ] NVIDIA Container Toolkit 설치 확인 (`docker run --gpus all` 가능 여부)
- [ ] 파일 번들 수신 및 압축 해제
- [ ] `.env`의 `DISK_MONITOR_PATHS` → 실제 파티션 경로로 수정
- [ ] Docker 이미지 5종 로드 완료
- [ ] `docker compose up -d` 구동 성공
- [ ] Prometheus Targets 페이지에서 4개 Exporter 모두 UP 상태 확인
- [ ] Grafana 대시보드 3종 정상 로드 확인

---

## 7. 주요 이슈 및 주의사항

### DCGM Exporter GPU 접근 권한
GPU 서버에 **NVIDIA Container Toolkit**이 설치되어 있어야 `--gpus all` 또는 `deploy.resources.reservations.devices` 옵션이 동작함:
```bash
# GPU 서버에서 사전 확인
nvidia-smi                           # 드라이버 확인
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi  # 컨테이너 GPU 접근 확인
```

### 디스크 모니터링 경로 확인
GPU 서버에서 `df -h` 실행 후 위협이 되는 파티션 경로를 `.env`의 `DISK_MONITOR_PATHS`에 반영:
- 일반적으로 위험한 파티션: `/` (root), `/var/lib/docker`, `/data`, 모델 가중치 저장 경로 등

### cAdvisor `/dev/kmsg` 권한 오류
일부 커널에서 `--device=/dev/kmsg` 없이 cAdvisor 실행 시 경고 발생 가능. 심각한 오류는 아니나 필요 시 아래 옵션 추가:
```yaml
devices:
  - /dev/kmsg:/dev/kmsg
```

### Airgap 환경 이미지 태그 고정
`docker save/load` 시 태그가 보존됨. `docker-compose.yml`에서 `:latest` 태그를 사용해도 동작하나, 버전 고정이 필요하면 저장 전에 실제 태그 확인 후 명시할 것.
