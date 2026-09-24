# proxmox-sensors

Temperaturas (CPU / GPU / NVMe / HDD) no Proxmox VE: linha "Temperatures" no
Summary do nó + gráfico histórico junto dos de CPU/Rede/RAM.

Tudo — pré-requisitos, o que é alterado, garantias de segurança e rollback —
está documentado no cabeçalho de [`proxmox-enable-sensors.sh`](proxmox-enable-sensors.sh).

## Uso

```bash
# no host Proxmox, como root
bash proxmox-enable-sensors.sh              # aplica
bash proxmox-enable-sensors.sh --dry-run    # mostra o diff sem alterar nada
bash proxmox-enable-sensors.sh --status     # estado atual
bash proxmox-enable-sensors.sh --revert     # desfaz (--purge apaga o histórico)

# ou remotamente
ssh root@<IP-PROXMOX> "bash -s" < proxmox-enable-sensors.sh
```

Depois de um `apt upgrade` que atualize o `pve-manager`, rode de novo: os
patches somem, o histórico do RRD não.

Veio do repositório `k3s-cluster` (`scripts/proxmox-enable-sensors.sh`), com histórico.
