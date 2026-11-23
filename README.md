# chatgamelab-deploy (2.x)

My chatgamelab instances: one file each under `instances/`, set up with the
tools chatgamelab ships (`deploy/` in the app repository, see its README).
Each box installs signed releases by itself; its admin upgrades from the app,
under Server settings › Updates.

```
./deploy.sh dev.cgl.fmnoel.de                             # set up, or bring back to its file
./deploy.sh dev.cgl.fmnoel.de --admin you@example.org     # first setup: who becomes admin
./deploy.sh dev.cgl.fmnoel.de --ref v2.0.0-dev.3          # from another release
```

`deploy.sh` takes the newest release on the instance's `release_channel` from
chatgamelab's release index, fetches the app repository at that tag into
`.cache/` and runs its `deploy/setup.sh` with the instance file. On a new box
that release is installed; a box that runs a version keeps it.

| Instance | Channel |
|---|---|
| `dev.cgl.fmnoel.de` | prerelease |

## Instance files

Public values only (Auth0 identifiers, Sentry DSNs, the backup target, the SSH
keys allowed in as `cgl`); the keys are chatgamelab's `deploy/example.yml`.
The secrets stay on the box: the database password is generated there, the
backup key and the first admin's address are given once (`--backup-key`,
`--admin`).

## Requirements

git, ssh, curl, jq and ansible on this machine; root SSH access to the box;
DNS for the domain pointing at it. The first connection asks to confirm the
box's host key against the fingerprints the provider shows.
