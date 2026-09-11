# The CI trigger

`.github/workflows/docker-image.yml` in the **application** repository has a
`webhook` job that currently posts to two Coolify endpoints. The `development`
branch of that job is what moves to this deployment; the `main` branch stays on
Coolify until production migrates.

Replace the `webhook` job's body with:

```yaml
  webhook:
    # Kept downstream of the image build deliberately, even though the box
    # builds from source and needs no image: it means the dev box is only ever
    # asked to deploy a commit that has already compiled once in CI.
    needs: [build-and-push, resolve-version]
    runs-on: ubuntu-latest
    steps:
      - name: Trigger the dev box
        if: github.ref_name == 'development'
        env:
          SECRET: ${{ secrets.CGL_DEPLOY_HOOK_SECRET }}
        run: |
          # The body carries no instruction and is never parsed by the
          # listener — it is read only to be hashed. It is here because a POST
          # with no body carries no Content-Length and is answered 411.
          body='{"ref":"${{ github.ref_name }}","sha":"${{ github.sha }}"}'
          sig="$(printf '%s' "$body" \
            | openssl dgst -sha256 -hmac "$SECRET" -r | cut -d' ' -f1)"
          # An accepted trigger answers 202, not 200: the deploy it starts
          # outlives the request by minutes. curl -f treats any 2xx as success.
          curl -fsS -X POST \
            -H 'Content-Type: application/json' \
            -H "X-Hub-Signature-256: sha256=$sig" \
            --data-raw "$body" \
            https://cgl.fmnoel.de/_hooks/deploy \
            || echo "trigger failed — the box's 15-minute timer still converges"

      - name: Trigger Coolify prod
        if: github.ref_name == 'main'
        run: |
          curl -X POST -f \
            -H "Authorization: Bearer ${{ secrets.COOLIFY_WEBHOOK_TOKEN }}" \
            "${{ secrets.COOLIFY_WEBHOOK_URL_PROD }}" \
            || echo "⚠️ Coolify prod webhook failed"
```

`CGL_DEPLOY_HOOK_SECRET` needs no setting up by hand: `./deploy.sh` mints a
fresh one on every run and writes both ends itself — the GitHub Actions secret
and the file on the box. It requires `gh` to be authenticated with admin on the
application repository.

`COOLIFY_WEBHOOK_URL` (the dev one) becomes unused and can be deleted from the
repository's secrets once this lands.

## What the trigger does and does not do

It carries no content and grants no access. The listener verifies the
signature, ignores the body, and touches one file; `box/cgl-update` then
resolves the tracked branch **itself** and deploys whatever its head is now.
So a forged or replayed trigger buys an attacker one convergence onto the
branch the box already follows, which is what it was going to do within the
quarter hour anyway.

It also means the commit deployed can be newer than the commit that fired the
trigger — two merges in quick succession may produce one deploy of the second.
That is intended: the box converges on a branch rather than replaying a queue.

Nothing on the box is ever issued to CI: no SSH key, no deploy credential. The
shared secret is machine-to-machine, rotated on every `./deploy.sh` run, and
no human handles it.
