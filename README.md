# PVE Info

Petit script Bash pour afficher un rapport Proxmox VE (noeud, VMs, stockages) avec `pvesh` et `jq`.

## Prerequis

- Proxmox VE (executer sur un noeud PVE)
- `pvesh`
- `jq`
- `numfmt` (coreutils)

## Utilisation

```bash
./pveinfo.sh
```

Options :

```bash
./pveinfo.sh -n <NODE> -l <LIMIT>
```

- `-n` : nom du noeud (auto si omis)
- `-l` : limite du nombre de VMs affichees (0 = toutes)

Variables d'environnement :

- `PVE_SH` : chemin de `pvesh`
- `JQ_BIN` : chemin de `jq`
- `LIMIT` : limite de VMs (meme effet que `-l`)

## Ce que fait le script

- CPU du noeud : via `rrddata` (moyenne sur l'heure)
- RAM et rootfs : via `/nodes/<node>/status`
- VMs :
  - CPU : via `rrddata` (moyenne)
  - RAM : via `rrddata` (fallback sur `status/current`)
  - Disque : utilise/provisionne via l'API storage
  - Auto-start : `onboot` (Yes/No)
  - Snapshots : nombre de snapshots (hors `current`)
  - Backups : nombre de backups trouves sur les storages du noeud

## Notes

- Les valeurs CPU de `rrddata` sont lissees et peuvent differer de `/status`.
- L'occupation disque VM depend du backend de stockage.
