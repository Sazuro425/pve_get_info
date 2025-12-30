#!/usr/bin/env bash
set -euo pipefail

# Rapport PVE en shell : nécessite pvesh + jq.

PVE_SH="${PVE_SH:-pvesh}"
JQ_BIN="${JQ_BIN:-jq}"
LIMIT="${LIMIT:-0}"
NODE=""

usage() {
  cat <<'EOF'
Usage: report.sh [-n NODE] [-l LIMIT]
  -n NODE   Nom du noeud PVE (auto si omis)
  -l LIMIT  Limite de VMs affichées (défaut: 0 = toutes)
Env : PVE_SH (chemin pvesh), JQ_BIN (chemin jq), LIMIT.
EOF
}

while getopts ":n:l:h" opt; do
  case "$opt" in
    n) NODE="$OPTARG" ;;
    l) LIMIT="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

command -v "$PVE_SH" >/dev/null 2>&1 || { echo "Erreur: $PVE_SH introuvable (lancer sur un nœud PVE)." >&2; exit 1; }
command -v "$JQ_BIN" >/dev/null 2>&1 || { echo "Erreur: jq est requis (apt install jq)." >&2; exit 1; }

json() { "$PVE_SH" get "$1" --output-format json; }

detect_node() {
  local host nodes first
  host="$(hostname -s)"
  nodes="$(json /nodes)"
  first="$(printf '%s' "$nodes" | "$JQ_BIN" -r '.[0].node // empty')"
  if printf '%s' "$nodes" | "$JQ_BIN" -e --arg h "$host" '.[] | select(.node==$h)' >/dev/null 2>&1; then
    echo "$host"
  elif [[ -n "$first" ]]; then
    echo "$first"
  else
    echo "Aucun nœud détecté via pvesh." >&2
    exit 1
  fi
}

NODE="${NODE:-$(detect_node)}"

status="$(json "/nodes/$NODE/status")"
rrd="$("$PVE_SH" get "/nodes/$NODE/rrddata" --timeframe hour --output-format json)"
cpu_pct="$(printf '%s' "$rrd" | "$JQ_BIN" -r '((.[-1].cpu // 0) * 100) | tonumber')"
cpu_pct_fmt="$(printf '%.2f' "$cpu_pct")"
mem_used="$(printf '%s' "$status" | "$JQ_BIN" -r '.memory.used // 0')"
mem_tot="$(printf '%s' "$status" | "$JQ_BIN" -r '.memory.total // 0')"
root_used="$(printf '%s' "$status" | "$JQ_BIN" -r '.rootfs.used // 0')"
root_tot="$(printf '%s' "$status" | "$JQ_BIN" -r '.rootfs.total // 0')"
uptime="$(printf '%s' "$status" | "$JQ_BIN" -r '.uptime // 0')"
load="$(printf '%s' "$status" | "$JQ_BIN" -c '.loadavg // []')"

bytes_h() { numfmt --to=iec --suffix=B --format="%.1f" "$1" 2>/dev/null || echo "$1"; }

echo "=== PVE Report: $NODE ==="
echo "Uptime: ${uptime}s | Load: $load"
echo "CPU: ${cpu_pct_fmt}% | RAM: $(bytes_h "$mem_used")/$(bytes_h "$mem_tot")"
echo "RootFS: $(bytes_h "$root_used")/$(bytes_h "$root_tot")"
echo

echo "VMs (tri CPU, limite ${LIMIT})"
vms="$(json "/nodes/$NODE/qemu")"
storage_list="$(json "/nodes/$NODE/storage")"
backup_jsons=()
while IFS= read -r storage; do
  backup_jsons+=("$("$PVE_SH" get "/nodes/$NODE/storage/$storage/content" --content backup --output-format json 2>/dev/null || echo '[]')")
done < <(printf '%s' "$storage_list" | "$JQ_BIN" -r '.[].storage')
backups_all="$(printf '%s\n' "${backup_jsons[@]}" | "$JQ_BIN" -s 'add')"

collect_vm_table() {
  local vmid info rrd_vm cfg cpu cpu_fmt name status memu memt disku diskt onboot autostart storages storage content used_s size_s template snapshot_list snap_count backup_count
  printf '%s' "$vms" | "$JQ_BIN" -r '.[].vmid' | while read -r vmid; do
    info="$(json "/nodes/$NODE/qemu/$vmid/status/current")"
    rrd_vm="$("$PVE_SH" get "/nodes/$NODE/qemu/$vmid/rrddata" --timeframe hour --output-format json)"
    cfg="$(json "/nodes/$NODE/qemu/$vmid/config")"
    template="$(printf '%s' "$cfg" | "$JQ_BIN" -r '.template // 0')"
    if [[ "$template" -eq 1 ]]; then
      continue
    fi
    cpu="$(printf '%s' "$rrd_vm" | "$JQ_BIN" -r '((.[-1].cpu // 0) * 100) | tonumber')"
    cpu_fmt="$(printf '%.2f' "$cpu")"
    name="$(printf '%s' "$info" | "$JQ_BIN" -r '.name // ("vm-" + (.vmid|tostring))')"
    status="$(printf '%s' "$info" | "$JQ_BIN" -r '.status // "unknown"')"
    memu="$(printf '%s' "$rrd_vm" | "$JQ_BIN" -r '.[-1].mem // 0')"
    memt="$(printf '%s' "$rrd_vm" | "$JQ_BIN" -r '.[-1].maxmem // 0')"
    disku=0
    diskt=0
    storages="$(printf '%s' "$cfg" | "$JQ_BIN" -r 'to_entries[] | select(.key|test("^(scsi|virtio|sata|ide)[0-9]+$")) | .value | split(":")[0]' | sort -u)"
    for storage in $storages; do
      content="$("$PVE_SH" get "/nodes/$NODE/storage/$storage/content" --vmid "$vmid" --content images --output-format json 2>/dev/null || echo '[]')"
      used_s="$(printf '%s' "$content" | "$JQ_BIN" -r 'map(.used // 0) | add // 0')"
      size_s="$(printf '%s' "$content" | "$JQ_BIN" -r 'map(.size // 0) | add // 0')"
      disku=$((disku + used_s))
      diskt=$((diskt + size_s))
    done
    if [[ "$memt" -eq 0 ]]; then
      memt="$(printf '%s' "$info" | "$JQ_BIN" -r '.maxmem // 0')"
    fi
    if [[ "$diskt" -eq 0 ]]; then
      disku="$(printf '%s' "$info" | "$JQ_BIN" -r '.disk // 0')"
      diskt="$(printf '%s' "$info" | "$JQ_BIN" -r '.maxdisk // 0')"
    fi
    snapshot_list="$(json "/nodes/$NODE/qemu/$vmid/snapshot")"
    snap_count="$(printf '%s' "$snapshot_list" | "$JQ_BIN" -r 'map(select(.name != "current")) | length')"
    backup_count="$(printf '%s' "$backups_all" | "$JQ_BIN" -r --arg vmid "$vmid" 'map(select((.vmid // "")|tostring == $vmid)) | length')"
    onboot="$(printf '%s' "$cfg" | "$JQ_BIN" -r '.onboot // 0')"
    if [[ "$onboot" -eq 1 ]]; then
      autostart="Yes"
    else
      autostart="No"
    fi
    printf "%s\t%s\t%s\t%s%%\t%s/%s\t%s/%s\t%s\t%s\t%s\n" \
      "$vmid" "$name" "$status" "$cpu_fmt" \
      "$(bytes_h "$memu")" "$(bytes_h "$memt")" \
      "$(bytes_h "$disku")" "$(bytes_h "$diskt")" \
      "$autostart" "$snap_count" "$backup_count"
  done | sort -k4 -r -n
}

vm_table="$(collect_vm_table)"
if [[ "$LIMIT" -gt 0 ]]; then
  vm_table="$(printf '%s\n' "$vm_table" | head -n "$LIMIT")"
fi
if [[ -z "$vm_table" ]]; then
  echo "(aucune VM)"
else
  {
    echo -e "VMID\tNom\tStatut\tCPU\tRAM\tDisque\tAuto-start\tSnapshots\tBackups"
    printf '%s\n' "$vm_table"
  } | column -t -s $'\t'
fi

echo
echo "Stockages:"
json "/nodes/$NODE/storage" | "$JQ_BIN" -r '.[] | "\(.storage)\t\(.type)\t\(.used // 0)\t\(.total // 0)"' \
  | while IFS=$'\t' read -r name type used total; do
      printf "%s\t%s\t%s/%s\n" "$name" "$type" "$(bytes_h "$used")" "$(bytes_h "$total")"
    done \
  | column -t -s $'\t'
