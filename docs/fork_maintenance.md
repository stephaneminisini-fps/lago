# Fork maintenance

This repository is FPS's fork of [getlago/lago](https://github.com/getlago/lago).
It differs from upstream in one way: every premium feature is unlocked, without
a Lago license key. This page explains what the fork changes, how to build the
image, and how to take a new upstream release without losing those changes.

## What the fork changes

All code changes live in the `api` submodule (`stephaneminisini-fps/lago-api`).
The frontend has no changes: it only shows premium features when the API says
they are enabled.

| Change | Where |
|---|---|
| The license check no longer calls Lago's license server; premium is enabled at boot in every environment except `test` | `api/lib/lago_utils/lago_utils/license.rb`, `api/config/initializers/license.rb` |
| The unused `license_url` setting is removed | `api/config/environments/*.rb` |
| A migration enables every premium integration on existing organizations and makes that the column default for new ones | `api/db/migrate/20260928120000_enable_all_premium_integrations_on_organizations.rb` |
| Specs for the above; the organization factory and `Organization` spec subject start with no integrations so upstream specs keep testing the locked behaviour | `api/spec/...` |

Individual integrations can still be switched off per organization, for example
`issue_receipts` or `from_email`, which change behaviour as soon as they are
enabled. Use the existing admin API (`PUT /admin/organizations/:id` with a
`premium_integrations` array; requires the `ADMIN_API_KEY` environment variable)
or a Rails console in the container.

Some integrations (NetSuite, Xero, HubSpot, Salesforce) rely on services Lago
hosts. They appear in the UI but need that backend configured to work.

## Branch layout

| Repository | Branch | Content |
|---|---|---|
| `stephaneminisini-fps/lago` | `main` | Upstream release + `.gitmodules` pointing at the forks + these docs and scripts |
| `stephaneminisini-fps/lago-api` | `fps` | Upstream API commit pinned by the release + the unlock changes |
| `stephaneminisini-fps/lago-front` | `fps` | Upstream frontend commit pinned by the release (no changes) |

The superproject pins commits on the `fps` branches. Only fast-forward those
branches (never squash or rebase them), so every pinned commit stays reachable.
When merging a pull request into `fps`, use "Create a merge commit".

## Building and publishing the image

The all-in-one image (`docker/Dockerfile`) compiles `api/` and `front/` from
source. Build it from a checkout of `main` with submodules:

```bash
git clone --recurse-submodules https://github.com/stephaneminisini-fps/lago.git
cd lago

REGISTRY=904845703353.dkr.ecr.us-east-1.amazonaws.com
TAG=v1.53.0-fps.1   # <upstream version>-fps.<build number>, never "latest"

aws ecr get-login-password --profile fps-ai-dev --region us-east-1 |
  docker login --username AWS --password-stdin "$REGISTRY"

docker build --platform linux/amd64 -f docker/Dockerfile -t "$REGISTRY/lago:$TAG" .
docker push "$REGISTRY/lago:$TAG"
```

The ECR repository uses immutable tags: bump the `-fps.N` suffix for every new
build of the same upstream version.

In the deployment compose file, replace the upstream image with the fork's:

```yaml
services:
  lago:
    image: 904845703353.dkr.ecr.us-east-1.amazonaws.com/lago:v1.53.0-fps.1
```

The container runs `db:migrate` on every boot (`docker/runner.sh`), so the
fork's migrations apply automatically on the first start of a new image.

### Separate-container setup (`docker-compose.yml`)

The root `docker-compose.yml` runs the API and the frontend as separate
images. Only the API image needs to come from the fork: the frontend has no
changes, so `getlago/front:<version>` stays. Build and push the API image:

```bash
docker build --platform linux/amd64 -f api/Dockerfile -t "$REGISTRY/lago-api:$TAG" api
docker push "$REGISTRY/lago-api:$TAG"
```

Then change the one shared backend image in `docker-compose.yml`; `migrate`,
`api`, `api-worker` and `api-clock` all use it:

```yaml
x-backend-image: &backend-image
  image: 904845703353.dkr.ecr.us-east-1.amazonaws.com/lago-api:v1.53.0-fps.1
```

The `migrate` service applies the fork's migrations on `docker compose up`.
Keeping `getlago/api` here leaves every premium feature locked, whatever the
frontend image.

## Taking a new upstream release

A new upstream release never changes the fork on its own. To take it:

```bash
cd lago                               # clean checkout of main
scripts/sync-upstream.sh v1.54.0      # the upstream tag
```

The script:

1. Creates `sync/<tag>` off `origin/main` and merges the upstream tag.
2. In `api` and `front`, creates `sync/<tag>` off `origin/fps` and merges the
   commit the upstream tag pins.
3. Points the superproject at the merged submodule commits and commits.
4. Warns if upstream added premium integrations the fork does not enable.

It never pushes. It prints the push commands at the end.

Before merging anything it checks that each submodule's `fps` branch contains
the commit `main` pins, and stops (exit code 1) if not. That happens when a
submodule change was committed to the superproject but never published to
`fps`; publish it (or merge its pending pull request) and re-run.

The script's behaviour is covered by `tests/sync_upstream_test.sh`, which runs
it against small local repositories (no network). Run it after editing the
script.

### When the script stops on conflicts

It exits with code 2 and lists the conflicting files.

- **In `api` or `front`**: resolve, `git -C api add <files>`,
  `git -C api commit --no-edit`, then re-run the script with the same tag.
- **In the superproject**: resolve and `git add <files>` but do not commit;
  re-run the script, which commits once the submodules are merged.

Expected conflicts and how to resolve them:

| File | How often | Resolution |
|---|---|---|
| `api/db/structure.sql` | Almost every release (the `schema_migrations` list) | Keep both sides: upstream's new migrations and `20260928120000` |
| `api/lib/lago_utils/lago_utils/license.rb`, `api/config/initializers/license.rb` | Only if upstream edits the license check | Keep the fork's version (`verify` sets premium to true, no remote call) |
| `api/config/environments/*.rb` | Only if upstream edits the lines around `license_url` | Take upstream's changes, keep `license_url` removed |
| `api/app/models/organization.rb` (annotation comment) | Rare | Keep the fork's `premium_integrations` default |

### When upstream adds premium integrations

New integrations stay locked, because the fork's migration only lists the ones
that existed when it was written. The script warns about them, and the spec
`Organization premium_integrations default` fails. Add a migration named
`<timestamp>_enable_new_premium_integrations.rb` (the name and the
`PREMIUM_INTEGRATIONS = %w[...]` constant are what the script's check reads):

```ruby
# frozen_string_literal: true

class EnableNewPremiumIntegrations < ActiveRecord::Migration[8.0]
  PREMIUM_INTEGRATIONS = %w[
    new_integration_name
  ].freeze

  ALL_PREMIUM_INTEGRATIONS = %w[
    ...every name in Organization::PREMIUM_INTEGRATIONS...
  ].freeze

  def up
    safety_assured do
      change_column_default :organizations, :premium_integrations, to: ALL_PREMIUM_INTEGRATIONS

      execute <<~SQL
        UPDATE organizations
        SET premium_integrations = ARRAY(
          SELECT DISTINCT unnest(premium_integrations || ARRAY[#{PREMIUM_INTEGRATIONS.map { |i| connection.quote(i) }.join(", ")}]::varchar[])
        )
      SQL
    end
  end
end
```

Give each such migration a unique class name (for example suffix it with the
version: `EnableNewPremiumIntegrationsV1540`) and a matching file name.

### Checks after every sync

1. Run the API specs, at least `spec/models/organization_spec.rb` and
   `spec/lib/lago_utils/license_spec.rb`.
2. Look for new gating that the fork does not cover, since it merges without
   conflicts: `git -C api diff <old-fps>..HEAD -- app lib | grep -n "premium\|License"`.
3. Publish the submodules first, then the superproject:
   `git -C api push origin sync/<tag>:fps`, `git -C front push origin sync/<tag>:fps`,
   `git push -u origin sync/<tag>`, and open a pull request into `main`.
4. After merging, build and push the image with a new tag, update the
   deployment compose file, and deploy.

## What would lose the fork's changes

- Pointing the deployment back at `getlago/lago:<version>`.
- Using GitHub's "Discard commits" button on any of the three forks.
- Squash- or rebase-merging into an `fps` branch, which orphans pinned commits.
