#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

usage() {
  cat <<'EOF'
Uso:
  ./gpu_bench.sh [--update-baseline] [--no-diff]

Qué hace:
  - Ejecuta nvbandwidth, memtest_vulkan y glmark2 (si existen)
  - Guarda outputs crudos por test en ./benchmarks/<timestamp>/
  - Genera summary.csv con métricas parseadas
  - Si existe ./benchmarks/baseline/summary.csv, compara y marca OK/WARN/FAIL
  - Opcional: hace diff de outputs contra baseline

Opciones:
  --update-baseline   Copia ESTE run como nuevo baseline (con backup del anterior)
  --no-diff           No hacer diff de outputs (solo comparación numérica)

Config por variables de entorno:
  BASE_DIR=...        (default: ./benchmarks)
  COOLDOWN=...        segundos entre tests (default: 15)
  WARN_PCT=...        umbral WARN % (default: 5)
  FAIL_PCT=...        umbral FAIL % (default: 10)

  NV_CMD=...          (default: ./nvbandwidth)
  MEMTEST_CMD=...     (default: ./memtest_vulkan)
  GLMARK_CMD=...      (default: ./glmark2)
EOF
}

# ---------------- CONFIG ----------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${BASE_DIR:-$SCRIPT_DIR/benchmarks}"
RUN_ID="$(date +'%Y-%m-%d_%H-%M-%S')"
RUN_DIR="$BASE_DIR/$RUN_ID"
LATEST_LINK="$BASE_DIR/latest"
BASELINE_DIR="$BASE_DIR/baseline"

COOLDOWN="${COOLDOWN:-15}"

NV_CMD="${NV_CMD:-./nvbandwidth}"
MEMTEST_CMD="${MEMTEST_CMD:-./memtest_vulkan}"
GLMARK_CMD="${GLMARK_CMD:-./glmark2}"
MEMTEST_TIMEOUT="${MEMTEST_TIMEOUT:-420}"
MEMTEST_FORCE_TTY="${MEMTEST_FORCE_TTY:-1}"
MEMTEST_AUTO_KEYPRESS="${MEMTEST_AUTO_KEYPRESS:-1}"

WARN_PCT="${WARN_PCT:-5}"
FAIL_PCT="${FAIL_PCT:-10}"
AWK_BIN="${AWK_BIN:-$(command -v gawk || command -v awk || true)}"

UPDATE_BASELINE=0
NO_DIFF=0
# ---------------------------------------

for arg in "$@"; do
  case "$arg" in
    --update-baseline) UPDATE_BASELINE=1 ;;
    --no-diff) NO_DIFF=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Argumento desconocido: $arg"; usage; exit 2 ;;
  esac
done

mkdir -p "$RUN_DIR"

SUMMARY_CSV="$RUN_DIR/summary.csv"
COMPARE_TXT="$RUN_DIR/compare_vs_baseline.txt"

# Cabecera CSV
echo "test,metric,value,unit,better" > "$SUMMARY_CSV"

log() { printf '%s\n' "$*"; }

strip_ansi() {
  # Quita códigos ANSI (colores) por si algún benchmark los mete
  sed -r 's/\x1B\[[0-9;]*[mK]//g'
}

sanitize_field() {
  # Campo seguro para CSV (sin comas, sin espacios raros)
  # Mantiene letras/números/._- y convierte resto a _
  echo "$1" | tr -cs 'A-Za-z0-9._+-' '_' | sed 's/^_//; s/_$//'
}

emit_metric() {
  local test="$1" metric="$2" value="$3" unit="$4" better="$5"
  test="$(sanitize_field "$test")"
  metric="$(sanitize_field "$metric")"
  unit="$(sanitize_field "$unit")"
  better="$(sanitize_field "$better")"
  # value se deja tal cual (numérico)
  echo "${test},${metric},${value},${unit},${better}" >> "$SUMMARY_CSV"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

try_enable_persistence() {
  if ! have_cmd nvidia-smi; then return 0; fi
  # Evita pedir password. Si no puede, no pasa nada.
  if have_cmd sudo && sudo -n true >/dev/null 2>&1; then
    sudo nvidia-smi -pm 1 >/dev/null 2>&1 || true
  else
    nvidia-smi -pm 1 >/dev/null 2>&1 || true
  fi
}

gpu_snapshot() {
  local outfile="$1"
  if ! have_cmd nvidia-smi; then
    echo "nvidia-smi no disponible" > "$outfile"
    return 0
  fi

  # Snapshot más “estable” que el nvidia-smi completo
  {
    echo "timestamp=$(date --iso-8601=seconds)"
    echo "nvidia_smi_version=$(nvidia-smi --version 2>/dev/null | tr '\n' ' ' || true)"
    echo
    echo "query_csv:"
    # Algunos campos pueden no existir según driver; si falla, cae a nvidia-smi normal
    if nvidia-smi --query-gpu=index,name,uuid,driver_version,pci.bus_id,pstate,temperature.gpu,power.draw,power.limit,clocks.sm,clocks.mem,utilization.gpu,utilization.memory,memory.used,memory.total --format=csv,noheader,nounits >/dev/null 2>&1; then
      echo "index,name,uuid,driver_version,pci.bus_id,pstate,tempC,powerW,powerLimitW,smMHz,memMHz,utilGpuPct,utilMemPct,memUsedMiB,memTotalMiB"
      nvidia-smi --query-gpu=index,name,uuid,driver_version,pci.bus_id,pstate,temperature.gpu,power.draw,power.limit,clocks.sm,clocks.mem,utilization.gpu,utilization.memory,memory.used,memory.total --format=csv,noheader,nounits
    else
      echo "(fallback) nvidia-smi"
      nvidia-smi || true
    fi
  } > "$outfile"
}

collect_env() {
  local outfile="$1"
  {
    echo "timestamp=$(date --iso-8601=seconds)"
    echo "host=$(hostname || true)"
    echo "kernel=$(uname -a || true)"
    if have_cmd lsb_release; then
      echo "distro=$(lsb_release -ds || true)"
    fi
    echo "pwd=$(pwd)"
    echo
    echo "GPU list:"
    if have_cmd nvidia-smi; then
      nvidia-smi -L || true
    else
      echo "nvidia-smi no disponible"
    fi
    echo
    echo "Vulkan (si existe vulkaninfo):"
    if have_cmd vulkaninfo; then
      vulkaninfo --summary 2>/dev/null || true
    else
      echo "vulkaninfo no disponible"
    fi
  } > "$outfile"
}

run_cmd_capture() {
  local name="$1" cmd="$2" out="$3" workdir="${4:-$PWD}" use_tty="${5:-0}" tty_out="${6:-}"
  local rc=0

  {
    echo "===== ${name} ====="
    echo "timestamp_start=$(date --iso-8601=seconds)"
    echo "cmd=${cmd}"
    echo "----------------------------------------"
  } > "$out"

  set +e
  if [[ "$use_tty" == "1" ]] && have_cmd script; then
    local tty_file="$tty_out"
    local script_rc=0
    if [[ -z "$tty_file" ]]; then
      tty_file="${out%.txt}.tty.txt"
    fi
    script -q -e -c "cd \"$workdir\" && bash -c \"$cmd\"" "$tty_file" >> "$out" 2>&1
    script_rc=$?
    if [[ "$script_rc" -eq 0 ]]; then
      rc=0
      if [[ -f "$tty_file" ]]; then
        {
          echo
          echo "----- tty transcript (capturado) -----"
          cat "$tty_file"
        } >> "$out"
      fi
    else
      {
        echo "note: script/pty no disponible (rc=${script_rc}), fallback a captura normal."
      } >> "$out"
      (
        cd "$workdir"
        bash -c "$cmd"
      ) >> "$out" 2>&1
      rc=$?
    fi
  else
    (
      cd "$workdir"
      bash -c "$cmd"
    ) >> "$out" 2>&1
    rc=$?
  fi
  set -e

  {
    echo "----------------------------------------"
    echo "timestamp_end=$(date --iso-8601=seconds)"
    echo "exit_code=${rc}"
  } >> "$out"

  echo "$rc"
}

is_timeout_exit() {
  local rc="$1"
  [[ "$rc" == "124" || "$rc" == "137" ]]
}

# -------- Parsers de métricas --------

parse_glmark2() {
  local out="$1"
  local score=""
  score="$(strip_ansi < "$out" | sed -n 's/.*[Ss]core:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -n1 || true)"
  if [[ -n "$score" ]]; then
    emit_metric "glmark2" "score" "$score" "points" "higher"
  fi

  # Métricas por escena: FPS (higher) y FrameTime (lower)
  strip_ansi < "$out" | "$AWK_BIN" '
    match($0, /^\[([^]]+)\][[:space:]]+(.+):[[:space:]]+FPS:[[:space:]]*([0-9.]+)[[:space:]]+FrameTime:[[:space:]]*([0-9.]+)[[:space:]]*ms/, m) {
      scene=m[1]
      cfg=m[2]
      fps=m[3]
      ft=m[4]
      gsub(/[[:space:]]+/, "_", cfg)
      gsub(/[^A-Za-z0-9_]+/, "_", cfg)
      metric_base=scene "_" cfg
      print metric_base "_fps|" fps "|fps|higher"
      print metric_base "_frametime|" ft "|ms|lower"
    }
  ' | while IFS='|' read -r metric val unit better; do
        [[ -n "${metric:-}" && -n "${val:-}" ]] || continue
        emit_metric "glmark2" "$metric" "$val" "$unit" "$better"
      done
}

parse_nvbandwidth() {
  local out="$1"
  [[ -n "$AWK_BIN" ]] || return 0
  # nvbandwidth suele exponer resultados útiles en líneas "SUM <test> <value>".
  strip_ansi < "$out" | "$AWK_BIN" '
    match($0, /^SUM[[:space:]]+([A-Za-z0-9_]+)[[:space:]]+([0-9]+([.][0-9]+)?)$/, m) {
      metric=m[1]
      val=m[2]
      unit="GB_s"
      better="higher"
      if (metric ~ /latency/) {
        unit="ns"
        better="lower"
      }
      print metric "|" val "|" unit "|" better
    }
  ' | while IFS='|' read -r metric val unit better; do
        [[ -n "${metric:-}" ]] || continue
        [[ -n "${val:-}" ]] || continue
        emit_metric "nvbandwidth" "$metric" "$val" "$unit" "$better"
      done
}

parse_memtest_vulkan() {
  local out="$1"
  local src="$out"
  local run_dir
  run_dir="$(dirname -- "$out")"
  if [[ -f "$run_dir/memtest_vulkan.log" ]]; then
    src="$run_dir/memtest_vulkan.log"
  fi

  local errors=""
  local written_bw=""
  local checked_bw=""
  errors="$(strip_ansi < "$src" | grep -Ei 'errors?' | tail -n1 | grep -Eo '[0-9]+' | tail -n1 || true)"
  if [[ -z "$errors" ]]; then
    # Si no aparece nada, asume 0 (muchos memtests solo imprimen “no errors”)
    if strip_ansi < "$src" | grep -qi 'no errors'; then
      errors="0"
    fi
  fi
  if [[ -n "$errors" ]]; then
    emit_metric "memtest_vulkan" "errors" "$errors" "count" "lower"
  fi

  written_bw="$(strip_ansi < "$src" | sed -n 's/.*written:[[:space:]]*[0-9.]\+GB[[:space:]]*\([0-9.]\+\)GB\/sec.*/\1/p' | tail -n1 || true)"
  checked_bw="$(strip_ansi < "$src" | sed -n 's/.*checked:[[:space:]]*[0-9.]\+GB[[:space:]]*\([0-9.]\+\)GB\/sec.*/\1/p' | tail -n1 || true)"
  if [[ -n "$written_bw" ]]; then
    emit_metric "memtest_vulkan" "written_bw" "$written_bw" "GB_s" "higher"
  fi
  if [[ -n "$checked_bw" ]]; then
    emit_metric "memtest_vulkan" "checked_bw" "$checked_bw" "GB_s" "higher"
  fi

  strip_ansi < "$src" | "$AWK_BIN" '
    /Standard 5-minute test PASSed/ { std_passed=1 }
    match($0, /([0-9]+)[[:space:]]+iteration\.[[:space:]]+Passed[[:space:]]+[0-9.]+[[:space:]]+seconds[[:space:]]+written:[[:space:]]*[0-9.]+GB[[:space:]]*([0-9.]+)GB\/sec[[:space:]]+checked:[[:space:]]*[0-9.]+GB[[:space:]]*([0-9.]+)GB\/sec/, m) {
      iter=m[1]
      w=m[2]
      c=m[3]
      last_iter=iter
      last_w=w
      last_c=c
      if (!std_passed) {
        std_last_iter=iter
        std_last_w=w
        std_last_c=c
      } else {
        ext_last_iter=iter
        ext_last_w=w
        ext_last_c=c
      }
    }
    END {
      if (std_last_iter != "") print "std_last_iter|" std_last_iter "|count|higher"
      if (std_last_w != "") print "std_last_written_bw|" std_last_w "|GB_s|higher"
      if (std_last_c != "") print "std_last_checked_bw|" std_last_c "|GB_s|higher"
      if (ext_last_iter != "") print "ext_last_iter|" ext_last_iter "|count|higher"
      if (ext_last_w != "") print "ext_last_written_bw|" ext_last_w "|GB_s|higher"
      if (ext_last_c != "") print "ext_last_checked_bw|" ext_last_c "|GB_s|higher"
      if (last_iter != "") print "last_iter|" last_iter "|count|higher"
    }
  ' | while IFS='|' read -r metric val unit better; do
        [[ -n "${metric:-}" && -n "${val:-}" ]] || continue
        emit_metric "memtest_vulkan" "$metric" "$val" "$unit" "$better"
      done
}

# -------- Comparador numérico --------

compare_summaries() {
  local base_csv="$1"
  local cur_csv="$2"
  local report="$3"
  [[ -n "$AWK_BIN" ]] || return 2

  "$AWK_BIN" -F',' -v warn="$WARN_PCT" -v fail="$FAIL_PCT" '
    function abs(x){ return x<0 ? -x : x }

    NR==1 && FNR==1 { next }           # salta header baseline
    FNR==NR {
      key=$1 SUBSEP $2
      b[key]=$3+0
      u[key]=$4
      better[key]=$5
      next
    }

    FNR==1 { next }                    # salta header current
    {
      key=$1 SUBSEP $2
      if (!(key in b)) next

      cur=$3+0
      base=b[key]
      unit=u[key]
      be=better[key]

      if (base==0) {
        pct=0
      } else {
        pct=(cur-base)/base*100
      }
      delta=cur-base

      status="OK"
      # "higher" => regression si pct negativo por debajo de -warn/-fail
      # "lower"  => regression si pct positivo por encima de +warn/+fail
      if (be=="higher") {
        if (pct <= -fail) status="FAIL"
        else if (pct <= -warn) status="WARN"
      } else if (be=="lower") {
        if (pct >= fail) status="FAIL"
        else if (pct >= warn) status="WARN"
      }

      printf "%-4s | %-14s %-28s | %12.3f %-7s -> %12.3f %-7s | %+.3f (%+.2f%%)\n",
        status, $1, $2, base, unit, cur, unit, delta, pct

      if (status=="FAIL") has_fail=1
    }
    END { exit(has_fail?1:0) }
  ' "$base_csv" "$cur_csv" > "$report"
}

compare_summaries_node() {
  local base_csv="$1"
  local cur_csv="$2"
  local report="$3"
  local comparer="$SCRIPT_DIR/compare_summaries.js"
  if [[ ! -f "$comparer" ]] || ! have_cmd node; then
    return 2
  fi
  node "$comparer" --baseline "$base_csv" --current "$cur_csv" --warn-pct "$WARN_PCT" --fail-pct "$FAIL_PCT" > "$report"
}

# -------- Diff de outputs (opcional) --------

diff_tool() {
  # Orden de preferencia: difftastic -> delta (via git diff) -> colordiff -> diff
  if have_cmd difft; then
    echo "difft"
  elif have_cmd delta && have_cmd git; then
    echo "delta_via_git"
  elif have_cmd colordiff; then
    echo "colordiff -u"
  else
    echo "diff -u"
  fi
}

show_diff() {
  local a="$1" b="$2"
  local tool
  tool="$(diff_tool)"

  if [[ "$tool" == "difft" ]]; then
    difft "$a" "$b" || true
  elif [[ "$tool" == "delta_via_git" ]]; then
    git diff --no-index -- "$a" "$b" | delta --paging=never || true
  else
    # shellcheck disable=SC2086
    $tool "$a" "$b" || true
  fi
}

# ---------------- MAIN ----------------

log "========================================="
log "Benchmark run: $RUN_DIR"
log "BASE_DIR: $BASE_DIR"
log "========================================="
log

try_enable_persistence

collect_env "$RUN_DIR/env.txt"
gpu_snapshot "$RUN_DIR/gpu_before.txt"

run_one_test() {
  local name="$1" cmd="$2" parser="$3"

  if [[ -z "$cmd" ]]; then
    log "[$name] cmd vacío -> skip"
    return 0
  fi

  # Si es un path relativo tipo ./nvbandwidth, asegúrate de que existe
  # Si es un comando del PATH (glmark2), también vale.
  if [[ "$cmd" == ./* ]] && [[ ! -x "${cmd%% *}" ]]; then
    log "[$name] No existe o no es ejecutable: ${cmd%% *} -> skip"
    return 0
  fi

  log "-----------------------------------------"
  log "Running $name"
  log "CMD: $cmd"
  log "-----------------------------------------"

  local out="$RUN_DIR/${name}.out.txt"
  local side_log=""
  local tty_out=""
  local use_tty=0
  if [[ "$name" == "memtest_vulkan" ]]; then
    side_log="$SCRIPT_DIR/memtest_vulkan.log"
    tty_out="$RUN_DIR/memtest_vulkan.tty.txt"
    use_tty="$MEMTEST_FORCE_TTY"
    rm -f "$side_log"
    rm -f "$tty_out"
  fi

  local rc
  rc="$(run_cmd_capture "$name" "$cmd" "$out" "$SCRIPT_DIR" "$use_tty" "$tty_out")"

  if [[ "$name" == "memtest_vulkan" && -n "$side_log" ]]; then
    if [[ -f "$side_log" ]]; then
      cp -f "$side_log" "$RUN_DIR/memtest_vulkan.log"
      {
        echo
        echo "----- memtest_vulkan.log (capturado) -----"
        cat "$side_log"
      } >> "$out"
    else
      {
        echo
        echo "----- memtest_vulkan.log (capturado) -----"
        echo "no encontrado en: $side_log"
      } >> "$out"
    fi
  fi

  if [[ "$name" == "memtest_vulkan" ]] && is_timeout_exit "$rc"; then
    if strip_ansi < "$out" | grep -Eq 'iteration\.[[:space:]]+Passed'; then
      log "[memtest_vulkan] timeout con progreso válido; se considera corte controlado."
      echo "normalized_exit_code=0 (controlled_timeout_with_progress)" >> "$out"
      rc=0
    fi
  fi

  # Métrica de exit_code por si quieres detectarlo en baseline
  emit_metric "$name" "exit_code" "$rc" "code" "lower"

  # Parse métricas específicas
  if [[ -n "$parser" ]]; then
    "$parser" "$out" || true
  fi

  log "Cooling down ${COOLDOWN}s..."
  sleep "$COOLDOWN"
}

# Ejecuta secuencialmente
run_one_test "nvbandwidth"     "$NV_CMD"     "parse_nvbandwidth"
memtest_run_cmd="$MEMTEST_CMD"
if [[ "$MEMTEST_CMD" == "./memtest_vulkan" ]] && have_cmd timeout; then
  memtest_run_cmd="timeout --signal=INT ${MEMTEST_TIMEOUT} ./memtest_vulkan"
fi
if [[ "$MEMTEST_AUTO_KEYPRESS" == "1" ]] && have_cmd yes; then
  memtest_run_cmd="yes '' | ${memtest_run_cmd}"
fi
run_one_test "memtest_vulkan"  "$memtest_run_cmd" "parse_memtest_vulkan"
run_one_test "glmark2"         "$GLMARK_CMD" "parse_glmark2"

gpu_snapshot "$RUN_DIR/gpu_after.txt"

ln -sfn "$RUN_DIR" "$LATEST_LINK"

log
log "Benchmarks completed."
log "Logs & summary in: $RUN_DIR"
log "Summary: $SUMMARY_CSV"

# --- Comparación con baseline ---
if [[ -f "$BASELINE_DIR/summary.csv" ]]; then
  log
  log "========================================="
  log "Comparing vs baseline: $BASELINE_DIR"
  log "WARN_PCT=$WARN_PCT  FAIL_PCT=$FAIL_PCT"
  log "========================================="

  set +e
  compare_summaries_node "$BASELINE_DIR/summary.csv" "$SUMMARY_CSV" "$COMPARE_TXT"
  cmp_rc=$?
  if [[ "$cmp_rc" -eq 2 ]]; then
    compare_summaries "$BASELINE_DIR/summary.csv" "$SUMMARY_CSV" "$COMPARE_TXT"
    cmp_rc=$?
  fi
  set -e

  cat "$COMPARE_TXT"

  if [[ "$NO_DIFF" -eq 0 ]]; then
    log
    log "---- Output diff (baseline vs current) ----"
    for f in nvbandwidth.out.txt memtest_vulkan.out.txt glmark2.out.txt; do
      if [[ -f "$BASELINE_DIR/$f" && -f "$RUN_DIR/$f" ]]; then
        log
        log "########## Diff: $f ##########"
        show_diff "$BASELINE_DIR/$f" "$RUN_DIR/$f"
      fi
    done
  fi

  if [[ "$cmp_rc" -ne 0 ]]; then
    log
    log "RESULT: FAIL (alguna métrica supera FAIL_PCT)"
    exit 1
  else
    log
    log "RESULT: OK (sin FAIL)"
  fi
else
  log
  log "No baseline en $BASELINE_DIR/summary.csv (aún)."
  log "Tip: ejecuta una vez con --update-baseline para fijar baseline."
fi

# --- Actualizar baseline (opcional) ---
if [[ "$UPDATE_BASELINE" -eq 1 ]]; then
  log
  log "========================================="
  log "Updating baseline -> $BASELINE_DIR"
  log "========================================="

  if [[ -d "$BASELINE_DIR" ]]; then
    mv "$BASELINE_DIR" "${BASELINE_DIR}.bak_${RUN_ID}" || true
  fi
  cp -a "$RUN_DIR" "$BASELINE_DIR"

  log "Baseline actualizado: $BASELINE_DIR"
fi
