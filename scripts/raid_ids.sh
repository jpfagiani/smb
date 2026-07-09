#!/bin/bash
# Gera a lista raid.devices com caminhos ESTÁVEIS (/dev/disk/by-id),
# baseados no WWN/serial de cada disco — imunes ao embaralhamento de
# nomes sdX entre boots. Cole a saída no group_vars/all.yml.
#
# Uso: sudo bash scripts/raid_ids.sh [/dev/mdX]
set -euo pipefail

MD="${1:-}"
if [ -z "$MD" ]; then
    MD=$(awk '/^md/{print "/dev/"$1; exit}' /proc/mdstat 2>/dev/null || true)
fi
[ -n "$MD" ] || { echo "ERRO: nenhum array md encontrado." >&2; exit 1; }

disco_estavel() {
    local dev="$1" alvo id melhor=""
    alvo=$(readlink -f "$dev")
    for id in /dev/disk/by-id/*; do
        [[ "$id" == *-part* ]] && continue
        [[ "$(readlink -f "$id")" == "$alvo" ]] || continue
        case "$(basename "$id")" in
            wwn-*) echo "$id"; return ;;
            *)     [[ -z "$melhor" ]] && melhor="$id" ;;
        esac
    done
    echo "${melhor:-$dev}"
}

SO_SRC=$(findmnt -n -o SOURCE /)
SO_DISK="/dev/$(lsblk -no PKNAME "$SO_SRC" 2>/dev/null | head -1)"

echo "# Array analisado : $MD"
echo "# Disco do sistema: $SO_DISK  (NUNCA incluir na lista)"
echo "#   id estável    : $(disco_estavel "$SO_DISK")"
echo ""
echo "# Substitua o bloco devices: do group_vars/all.yml por:"
echo "  devices:"
mdadm --detail "$MD" \
    | grep -oE '/dev/(sd[a-z]+|vd[a-z]+|nvme[0-9]+n[0-9]+)$' \
    | while read -r m; do
        echo "    - $(disco_estavel "$m")   # hoje: $m"
    done
