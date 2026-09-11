# Moving production to this deployment

Production currently runs on Coolify at a Hetzner VPS. This is how it becomes
`run.chatgamelab.eu`, deployed from this repository onto the Strato box that
already serves `prod.cgl.fmnoel.de`.

That box holds a **rehearsal** of production: `v1.57.0` with a restored dump of
the live database, and sign-in verified against restored accounts. So the steps
below have all been executed once already, against real data, with the one
exception noted at step 6.

## It is a rename, not a second instance

The obvious approach — adding `host_vars/run.chatgamelab.eu.yml` beside the
existing file — is wrong, and quietly so. An instance's identity is its domain,
but its *paths* are not: every instance uses `/opt/chatgamelab`,
`/var/lib/cgl`, the same container names and the same volume. Two host_vars
files pointing at one box therefore share all of that and overwrite each
other's `env.config`, where `PUBLIC_URL` and the Auth0 client differ per
domain. The stack would come up serving one name with the other's
configuration.

So the file moves rather than multiplies:

```sh
git mv ansible/host_vars/prod.cgl.fmnoel.de.yml ansible/host_vars/run.chatgamelab.eu.yml
```

and `ansible/inventory.ini` gains the new name in place of the old.

## Steps

**1. Auth0.** Add to the application's allowed lists, alongside the existing
entries rather than replacing them — production is still serving until step 4:

    Allowed Callback URLs   https://run.chatgamelab.eu/auth/login/auth0/callback
    Allowed Logout URLs     https://run.chatgamelab.eu/auth/logout/auth0/callback
    Allowed Web Origins     https://run.chatgamelab.eu

The same tenant as today, deliberately: `app_user.auth0_id` is tenant-scoped
and the middleware looks users up by it alone
(`server/api/httpx/auth.go:332`), with no fallback to email. A different tenant
locks out every restored account.

**2. DNS.** Point `run.chatgamelab.eu` at the Strato box — `194.164.195.64`
and `2a01:239:4c2:4a00::1`. Do this before step 5: certbot proves the name over
HTTP-01, so it has to resolve to the box already.

**3. Stop the old application.** Before the dump, not after — anything a user
does in between is lost, and a session mid-write is worse than a session
absent.

**4. Take the final dump** on the Coolify host:

```sh
docker exec <db-container> /usr/local/bin/backup.sh
```

It writes to `u541185-sub3`, which is the new box's own backup account, so the
dump arrives where step 6 will look for it. Check it landed and note the size;
the rehearsal's was 530 MB.

**5. Move the instance** and converge:

```sh
git mv ansible/host_vars/prod.cgl.fmnoel.de.yml ansible/host_vars/run.chatgamelab.eu.yml
$EDITOR ansible/inventory.ini      # prod.cgl.fmnoel.de -> run.chatgamelab.eu
git commit -am "feat: production moves to run.chatgamelab.eu" && git push
```

**6. Deploy and restore** in one command:

```sh
./deploy.sh run.chatgamelab.eu --restore-latest
```

This is the step the rehearsal exercised, under the other domain. It fetches
the newest dump from the box's own backup account (so half a gigabyte never
travels via a laptop), verifies it against the `.sha256` uploaded beside it,
drops the volume, brings up Postgres alone, loads the dump, checks the dump's
schema version against what the release can carry, and only then starts the
backend — which finds a populated database and runs just the migrations the
dump predates.

**7. Verify** before retiring anything:

```sh
curl -fsS https://run.chatgamelab.eu/api/version
ssh root@run.chatgamelab.eu /opt/chatgamelab/deploy/box/cgl-backup now
```

and sign in as a real account. The rehearsal took 2m16s from command to live.

**8. Remove the rehearsal's vhost.** Ansible templates a vhost per instance and
does not reap one it no longer knows about, so `prod.cgl.fmnoel.de` keeps being
served until:

```sh
ssh root@run.chatgamelab.eu 'rm -f /etc/nginx/sites-enabled/prod.cgl.fmnoel.de.conf \
  /etc/nginx/sites-available/prod.cgl.fmnoel.de.conf && nginx -t && systemctl reload nginx'
```

**9. Retire Coolify.** Its scheduled backup writes to the same account as the
new box, so switch it off rather than leaving two writers in one directory.

## What is different afterwards

Nothing converges on production by itself. It has no `track_branch`, no trigger
endpoint and no timer — `deploy.sh` naming a release is the only way anything
reaches it. `default_ref: main` makes `./deploy.sh run.chatgamelab.eu` deploy
whatever `main` last released, and refuses if that commit carries no `vX.Y.Z`
tag.

Rolling back is the same command with an older tag, and takes seconds where the
images are still in the local store. A tag older than the database's schema
version is refused, because migrations only run forwards
(`server/db/init.go:298`) and the set in between contains `DROP COLUMN` — so a
rollback across one needs `--restore` of a dump from that era.

## Known gaps at the time of writing

- **93% of the database is images.** 483 MB of 519 MB sits in
  `game_session_message.image`, and nothing purges it. A retention policy is
  being written separately; until it lands, the dump grows monotonically and
  with it the time every restore takes.
- **`DEV_MODE` was true on the old production.** The restored dump carries
  eight `@dev.local` accounts as evidence. This deployment sets it false for
  production, so they stop being recreated, but the rows persist — and they
  meant two unauthenticated routes were registered on the live system
  (`server/api/routes/router.go:81`). Worth deleting the rows once nothing
  references them.
- **One key per instance, but the main Storage Box account can read both.**
  Sub-account separation is real — each has its own
  `~/.ssh/authorized_keys` — so neither box can reach the other's backups.
  The main account's password can, and belongs nowhere near either machine.
