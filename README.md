# chatgamelab-deploy

Deployment of [chatgamelab](https://github.com/flocko-motion/chatgamelab) —
one instance per v-server, built on the box from source, run rootless under
podman behind native nginx.

```
./deploy.sh <server> [commit] [--reset-db <admin-email>] [--force-rebuild]
                              [--restore <dump.sql.gz>]

./deploy.sh dev.cgl.fmnoel.de                    # the instance's default_ref
./deploy.sh dev.cgl.fmnoel.de engineV2           # a branch CI never builds
./deploy.sh dev.cgl.fmnoel.de 68b1744 --force-rebuild
./deploy.sh prod.cgl.fmnoel.de v1.57.0
./deploy.sh prod.cgl.fmnoel.de --restore ~/cgl-prod.sql.gz
```

`<server>` is a domain, and it is the whole address of an instance: the file
`ansible/host_vars/<server>.yml`, the line in `ansible/inventory.ini`, the
certificate nginx serves, and the host SSH reaches. Adding an instance is one
file and one line.

Omit the commit and the instance's own `default_ref` applies — `development`
for the development box, `main` for production, whose head is the most recent
release. Naming one is therefore the deliberate act rather than the routine one.

`[commit]` is anything git resolves — a branch, a tag, a short or full SHA.
It is resolved on your machine to an immutable SHA before anything is asked of
the box, so a branch name never travels and two runs a day apart report which
commits they actually deployed.

## Why the box builds

CI publishes images for `main` and `development` alone, so trying a feature
branch meant publishing one first. The box builds from source instead, which
makes any reachable commit deployable, and tags each image by SHA — so a commit
built once comes back up in seconds from the local store, and hopping between
versions costs no network.

A deploy is therefore minutes rather than seconds. That is the trade, and it
was chosen deliberately.

Images are keyed by the application commit alone, so changing *how* they are
built — a build argument, a Dockerfile fix, the version string — leaves the
existing image in place: the cache is correct about the source and blind to the
recipe. `--force-rebuild` is how you say the recipe moved. The layer cache
still applies, so it is far cheaper than a first build.

## Why rootless

The build step runs other people's code: `npm ci` over 477 packages and their
install scripts. The database holds users' own OpenAI and Anthropic keys in
plaintext (`server/db/schema.sql:202`), which makes the Postgres volume the
thing worth protecting on this box.

So there are two unprivileged users with separate subordinate id ranges.
`cgl-build` builds and can reach neither the running containers nor the
volume; it has no podman socket at all, so a hostile package finds no API to
talk to. `cgl` runs the stack. Nothing runs as root except nginx's master
process and sshd, and the one sudoers entry that exists lets `cgl` act as
`cgl-build` — a downgrade, in the direction that does not matter.

Rootful Docker would offer the same convenience and neither boundary, since
membership in the `docker` group is root-equivalent.

## The two phases

`./deploy.sh` prepares the ground with ansible and then hands over to
`box/cgl-deploy`, which runs on the box and does the actual work. The box holds
its own clone of this repository and checks out the commit you ran `deploy.sh`
from, so what executes there is what you were reading here — which is also why
changing `box/` takes a push.

Ground setup is skipped when nothing under `ansible/` has changed since the box
last converged, so deploying another commit costs no ansible.

## Order of operations

Build, then destroy, then switch. A build that fails leaves the previous stack
serving with its data intact. `--reset-db` therefore drops the volume only once
the images it will be replaced by exist.

## Migrations

The application runs migrations forward only and has no down path
(`server/db/init.go:298`). Deploying an older commit over a newer schema is
silently permitted and sometimes wrong — the migration set contains
`DROP COLUMN` and `RENAME COLUMN`, and crossing one backwards gives a binary
querying columns that no longer exist, which fails at query time rather than at
startup.

So phase two compares the two and refuses to go backwards, naming
`--reset-db` as the way to do it on purpose. On a development instance that is
usually the right answer.

## Secrets

There are none in this repository, and that is what lets it be public.

Every value an instance needs is either public configuration in
`ansible/host_vars/<domain>.yml` — the Auth0 domain, audience and client id are
served to every visitor in `/env.js`, and a Sentry DSN is a write-only ingest
URL — or generated on the box and held only there. That second set is one
value: the Postgres password, which `box/cgl-env` generates once and then keeps,
since Postgres reads it only at `initdb`. When the stored value and the role
disagree, the file is treated as the truth and Postgres is brought to it, which
needs no secret because `postgres` authenticates over its own socket.

`--reset-db <admin-email>` is the one value a human supplies, and only at the
moment it can act: the admin bootstrap grants nothing once an admin exists
(`server/db/user_roles.go:55`), so a reset is the only time the address does
anything. Requiring it there makes locking yourself out of a fresh database
unreachable rather than merely discouraged.

## Dev mode

`DEV_MODE=true`, which gives debug logging and `db.Preseed`'s well-known dev
accounts. It is backend-only: the frontend's dev switch is Vite's build-time
`import.meta.env.DEV`, false in a production build, so sign-in goes through
Auth0 either way.

Two things make it safe to run on a reachable box, and both are load-bearing.

**`DEV_JWT_SECRET` stays unset.** Dev mode registers two routes with no
authentication at all (`server/api/routes/router.go:81`), and
`GET /api/users/{id}/jwt` signs a token for whatever user id the URL names —
while the dev admin ids are compile-time constants
(`server/db/preseed.go:20`). With a signing secret present, one unauthenticated
request to a guessable URL is admin. An empty secret makes `GenerateToken`
refuse, `compose.yml` never passes the variable to the container, and
`box/cgl-deploy` refuses to start a stack where both are set.

**nginx refuses both routes at the edge**, with 404. The other one,
`POST /api/users/new`, creates users without a credential, which is enough to
squat an address and block a real registration, since email is unique.

### The admin bootstrap

Preseed creates `admin-1@dev.local` and `admin-2@dev.local` holding the admin
role, and `CountAdmins` counts them — closing the `ADMIN_EMAILS` gate before
anyone has signed in. Those accounts carry no `auth0_id`, so nobody can
actually sign in as them, which would leave an instance with two unreachable
admins and a gate nobody can reopen.

So `box/cgl-deploy` drops their admin roles whenever no other admin exists,
holding the gate open for exactly the window it is for. Preseed restores the
roles on the next restart, by which point a real admin exists and the step does
nothing — which is why it runs on every deploy rather than only on
`--reset-db`.

## Auto-deploy

The box follows `track_branch` (`development`) on its own, so collaborators see
their merges without anyone running anything. Two routes ask for it and both
run the same systemd unit, so they serialise rather than race:

- **The trigger.** CI posts a signed, content-free POST to
  `https://<domain>/_hooks/deploy`. A localhost-bound listener verifies an
  HMAC-SHA256 over the raw body, ignores the body, and touches one file.
- **The timer**, every 15 minutes, which asks the same question regardless — so
  a trigger that never arrives delays a deploy rather than losing it.

`box/cgl-update` then resolves the branch head itself and hands off to
`box/cgl-deploy`. A forged or replayed trigger therefore buys one convergence
onto the branch the box already follows. Nothing on the box is issued to CI: no
SSH key, no deploy credential. The shared secret is machine-to-machine, minted
fresh by every `./deploy.sh` run and written to both ends by it, so it rotates
on its own and no human handles it.

An automatic run deploys application commits only. Changing the deployment
itself stays `./deploy.sh`'s job, which is what keeps a push to *this*
repository from reaching a box on its own.

`./deploy.sh <server> <commit>` overrides the branch, and that commit serves
until the next tick brings the box back onto it — so trying something out is
deliberate and temporary by construction.

See `docs/ci-trigger.md` for the application repository's side.

## Trust boundaries

`cgl.fmnoel.de` is a private developer instance. Production is expected to pass
to JFF and be administered by someone the dev instance's owner may never meet,
so the two share nothing that would let either reach the other: separate
v-servers, separate Auth0 accounts, separate audiences, separate Sentry
projects. There are no shared secrets because there are no secrets.

Two surfaces are worth keeping deliberate.

**This repository is code that runs as `cgl` and as root.** Anyone who can push
to it can change `box/` and `ansible/`. What protects an instance is that the
box checks out the commit its operator ran `./deploy.sh` from, rather than
following a branch — so nothing reaches a box until its own operator deploys
it. Do not add an automatic pull of this repository; it would trade that
property away. At handover, production should fork this repository rather than
share it, which leaves each operator unable to push into the other's boxes.

**The box builds from the application repository**, which means whoever
controls the branch being deployed controls code that compiles and runs here.
That is the real constraint on any automatic deploy trigger: a webhook that
builds whatever lands on `development` is safe exactly while the instance's
operator controls `development`.

## Requirements

**Your machine.** git, ssh, curl, ansible. `./deploy.sh` checks for each and
prints `apt` and `brew` lines for whatever is missing. Written for bash 3.2,
which is what macOS ships, and using no GNU-only tool.

**The box.** Debian 13 or newer, checked before anything runs — 13 is the floor
because that is where Debian's podman becomes 5.x. Key-based root SSH for the
first run only, since ground setup is what creates the unprivileged users.
About 4 GB of RAM, set by the frontend build running beside the stack. DNS
already resolving to the box, which certbot requires regardless.

**Before the first run.** Put your SSH public key in `deploy_public_keys` in
`ansible/group_vars/all.yml`, and the Auth0 client id for the instance's own
application in its `host_vars` file. `./deploy.sh` refuses to run while either
is a placeholder.
