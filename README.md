# proxmox-sensors

Temperaturas (CPU / GPU / NVMe / HDD) no Proxmox VE: linha "Temperatures" no
Summary do nó + gráfico histórico junto dos de CPU/Rede/RAM.

Tudo — pré-requisitos, o que é alterado, garantias de segurança e rollback —
está documentado no cabeçalho de [`proxmox-enable-sensors.sh`](proxmox-enable-sensors.sh).

## Uso

Da sua máquina, com acesso SSH de root ao host:

```bash
./run.sh <IP-PROXMOX> --setup      # 1ª vez: instala lm-sensors/drivetemp e aplica
./run.sh <IP-PROXMOX> --dry-run    # mostra o diff, não altera nada
./run.sh <IP-PROXMOX>              # aplica
./run.sh <IP-PROXMOX> --status     # estado atual
./run.sh <IP-PROXMOX> --revert     # desfaz (--purge apaga o histórico)
```

No PowerShell é igual, com `.
un.ps1` no lugar de `./run.sh`. O host pode vir
de `PVE_HOST`; sem usuário, vira `root@<host>`.

Direto no host Proxmox, como root: `bash proxmox-enable-sensors.sh [opções]`.

Depois de aplicar, recarregue a UI com Ctrl+F5.

Depois de um `apt upgrade` que atualize o `pve-manager`, rode de novo: os
patches somem, o histórico do RRD não.
