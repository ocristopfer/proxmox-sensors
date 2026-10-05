# proxmox-sensors

Temperaturas (CPU / GPU / NVMe / HDD) no Proxmox VE: linha "Temperatures" no
Summary do nó + gráfico histórico junto dos de CPU/Rede/RAM.

Tudo — pré-requisitos, o que é alterado, garantias de segurança e rollback —
está documentado no cabeçalho de [`proxmox-enable-sensors.sh`](proxmox-enable-sensors.sh).

## Instalação pelo pacote (recomendado)

No host Proxmox, como root:

```bash
wget https://github.com/ocristopfer/proxmox-sensors/releases/latest/download/pve-sensors_all.deb
apt install ./pve-sensors_all.deb
```

O pacote instala as dependências (`lm-sensors`, `librrds-perl`), carrega o
`drivetemp`, aplica os patches e reinicia a UI. Depois recarregue com Ctrl+F5.

- **Upgrade do `pve-manager`:** os patches são reaplicados sozinhos (com as
  mesmas opções da última vez), sem precisar rodar nada.
- **Comandos:** `pve-sensors --status`, `pve-sensors --dry-run`,
  `pve-sensors --no-graph`, `pve-sensors --revert` (desativa até você rodar
  `pve-sensors` de novo).
- **Desinstalar:** `apt remove pve-sensors` desfaz os patches e mantém o
  histórico; `apt purge pve-sensors` apaga o histórico também.
- Para instalar sem aplicar: `PVE_SENSORS_NO_APPLY=1 apt install ./pve-sensors_all.deb`.

Para gerar o pacote localmente: `packaging/build-deb.sh` (sai em `dist/`).
Uma release nova sai ao enviar uma tag: `git tag v1.0.0 && git push origin v1.0.0`.

## Uso sem o pacote (via SSH)

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

## Licença

[MIT](LICENSE)
