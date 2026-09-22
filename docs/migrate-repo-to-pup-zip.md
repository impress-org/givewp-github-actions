# Prompt: migrate an impress-org repo to the shared pup zip workflow

Copy everything below the line into Claude Code (or another agent) with the repo checked out, replacing
`<REPO>` with the repo name. It is written to stop and report rather than guess when a prerequisite is
missing, because a half-migrated repo silently produces zips the packaging bot can't find.

GiveWP core went first — see impress-org/givewp#8291 for a worked example of the result.

---

You are migrating `impress-org/<REPO>` from its bespoke `generate-zip.yml` to the shared StellarWP
pup-based zip workflow. Work through the phases in order and stop at the first blocker.

## Background you need

The packaging bot lives in `stellarwp/jenkins-scripts` (`includes/Commands/Package/ProductPlugin.php`).
When someone asks it for a zip it shallow-clones the repo and looks for a zip workflow in this order:

1. `.github/workflows/zip.yml`
2. `.github/workflows/generate-zip.yml`
3. `.github/workflows/zip-generator.yml`

It dispatches the **first** one it finds. So adding `zip.yml` switches the bot to the new path, and
deleting `zip.yml` switches it back — leave `generate-zip.yml` in place until the new path is proven.

The bot also predicts the zip's filename and checks S3 before dispatching anything, so it can serve a
cached zip instantly. pup produces exactly the same name — `<zip_name>.<version>` for production, and
`<zip_name>.<version>-dev-<git-commit-timestamp>-<8-char-hash>` for dev builds — so the cache keeps
working across the migration. **Do not change `zip_name` or the version regexes while migrating.**

## Phase 1 — check the prerequisites, and stop if any are missing

Report which of these the repo has. Do not create the missing ones yet; some are decisions for a human.

- [ ] `.puprc` at the repo root, with `zip_name`, `paths.versions`, and `build` / `build_dev` commands.
      Most add-ons don't have one. Without it `pup get-version` fails and the whole thing is a no-op.
- [ ] A `pup` script in `composer.json` that downloads and runs `pup.phar`, so `composer -- pup <cmd>`
      works. Copy GiveWP core's if it's missing.
- [ ] `.nvmrc`, if the build runs npm. The shared workflow reads the node version from it and **skips
      node setup entirely when it's absent** — the build then runs on whatever node the runner ships.
- [ ] `.distignore`, or `zip_use_default_ignore: true` in `.puprc`, so the zip doesn't ship dev files.
- [ ] Whether the repo ships a POT file. Check `languages/` in a zip the current `generate-zip.yml`
      produced. If there's a `<slug>.pot` in there, the migration has to carry the POT step across —
      see Phase 2. Every impress-org repo shipped one as of the core migration.

Then map the secrets. The shared workflow requires `GH_BOT_TOKEN` and `JENKINS_SECRET` plus five `S3_*`
values. impress-org stores the S3 ones under different names, so the caller maps them:

| shared workflow wants | pass it                     |
|-----------------------|-----------------------------|
| `GH_BOT_TOKEN`        | `GITHUB_TOKEN` — see below  |
| `JENKINS_SECRET`      | `SLACK_PACKAGING_SECRET`    |
| `S3_BUCKET`           | `ZIP_S3_BUCKET`             |
| `S3_ACCESS_KEY_ID`    | `ZIP_S3_ACCESS_KEY_ID`      |
| `S3_SECRET_ACCESS_KEY`| `ZIP_S3_SECRET_ACCESS_KEY`  |
| `S3_REGION`           | `ZIP_S3_REGION`             |
| `S3_ENDPOINT`         | `ZIP_S3_ENDPOINT`           |

`GH_BOT_TOKEN` is `required: true`, so something must be passed, but it doesn't have to be a bot PAT.
The shared workflow only uses it to check out the repo the workflow is running in, and the automatic
per-run `GITHUB_TOKEN` already covers that — including for private repos. A real bot token is only
needed when the checkout has to reach *outside* the repo, which is why TEC uses one: its zip workflow
also checks out `jenkins-scripts` and recurses into the `common` submodule.

So check whether this repo needs that reach — a `.gitmodules`, an `.npmrc` pointing at
`npm.pkg.github.com`, or a private `repositories` entry in `composer.json`. If it has none of those
(none of the give repos did as of the core migration), pass `GITHUB_TOKEN` and move on. If it has any of
them, stop and ask for a bot token before going further.

## Phase 2 — write `.github/workflows/zip.yml`

A thin caller only. Do not inline pup steps; the shared workflow owns those.

```yaml
name: Generate Zip

on:
    workflow_dispatch:
        inputs:
            ref:
                description: 'Git Commit Ref (branch, tag, or hash)'
                default: '<DEFAULT_BRANCH>'
                required: true
                type: string
            production:
                description: 'Is this a production build?'
                default: 'no'
                required: false
                type: choice
                options:
                    - 'yes'
                    - 'no'
            slack_channel:
                description: 'Slack channel ID to post to'
                required: false
                type: string
            slack_thread:
                description: 'Slack thread to post to'
                required: false
                type: string

jobs:
    zip:
        uses: stellarwp/github-actions/.github/workflows/zip.yml@main
        with:
            ref: ${{ inputs.ref }}
            production: ${{ inputs.production }}
            php_version: '<MIN_SUPPORTED_PHP>'
            slack_channel: ${{ inputs.slack_channel }}
            slack_thread: ${{ inputs.slack_thread }}
        secrets:
            # Only used to check out this repo, which the per-run token covers. See the note above.
            GH_BOT_TOKEN: ${{ secrets.GITHUB_TOKEN }}
            JENKINS_SECRET: ${{ secrets.SLACK_PACKAGING_SECRET }}
            S3_BUCKET: ${{ secrets.ZIP_S3_BUCKET }}
            S3_ACCESS_KEY_ID: ${{ secrets.ZIP_S3_ACCESS_KEY_ID }}
            S3_SECRET_ACCESS_KEY: ${{ secrets.ZIP_S3_SECRET_ACCESS_KEY }}
            S3_REGION: ${{ secrets.ZIP_S3_REGION }}
            S3_ENDPOINT: ${{ secrets.ZIP_S3_ENDPOINT }}
```

Fill in `<DEFAULT_BRANCH>` from the repo, and `<MIN_SUPPORTED_PHP>` from the `Requires PHP` header in
`readme.txt` — build on the minimum supported version so the vendor directory stays compatible with it.

Three mistakes to avoid, in order of how quietly they fail:

1. **`production` must be `type: choice` with `yes`/`no`.** The shared workflow compares it against the
   string `'yes'`, and the bot only converts to `yes`/`no` for choice-typed inputs. Declared as a
   boolean, the bot sends `true`, which reads as *not* production — you get a dev zip on a release, and
   nothing errors.
2. **Don't rename the inputs.** The bot sends `ref`, `slack_channel`, `slack_thread` and `production`
   by those exact names.
3. **Match the repo's existing YAML indentation** (impress-org repos use 4 spaces).

The shared workflow also takes `i18n`, `check` and `additional_commands`. Leave `i18n` and `check` at
their defaults unless there's a reason, but read the next section before skipping `additional_commands`.

### Carry the POT file across, or the zip silently loses it

`generate-zip.yml` had an explicit `Generate pot file` step. **pup has no equivalent, and nothing in the
shared workflow replaces it.**

`pup i18n` looks like the equivalent and is not: it *downloads* finished translations from a GlotPress
instance. It does not generate a POT from source. With no `i18n` section in `.puprc` it exits
immediately — in the GiveWP core run it took 0.18 seconds — and the step still reports success. The zip
ends up with a `languages/` directory containing nothing but `.gitkeep`, and nothing anywhere fails.

This is why the Phase 1 checklist asks whether the repo ships a POT. If it does, generate it through
`additional_commands`, which the shared workflow runs after `pup build` and before `pup package` —
the only window where the file will be picked up:

```yaml
            # pup has no POT generation of its own: `pup i18n` pulls finished translations down from
            # GlotPress, it does not produce the source POT. Generate it here, which the shared workflow
            # runs after `pup build` and before `pup package`, so languages/<slug>.pot ends up in the zip.
            # WP-CLI is already on the PATH by this point - the shared workflow installs it.
            additional_commands: |
                php -d xdebug.mode=off "$(which wp)" i18n make-pot "$GITHUB_WORKSPACE" "$GITHUB_WORKSPACE/languages/<SLUG>.pot" --exclude="$(cat .distignore | tr "\n" "," | sed 's/,$/ /' | tr " " "\n"),src/**/*.js,*.js.map,blocks/**/*.js"
```

Copy the `--exclude` list from whatever the repo's `generate-zip.yml` used rather than the above, since
it varies by repo. Also confirm `.distignore` has no `languages` entry, or the file gets generated and
then dropped from the zip.

A production build is enough. GiveWP core's `release.yml` ran `npm run dev`, generated the POT, then ran
`npm run build`, and the POT from a production-only build proved byte-identical apart from the
`POT-Creation-Date` header — 6,434 msgids either way. The dev build is not load-bearing here.

## Phase 3 — verify before opening the PR

- `pup get-version` prints a real version, not `unknown`. If it prints `unknown`, the regex in `.puprc`
  doesn't match the version file — pup's match is case sensitive, and some readmes say `Stable Tag:`
  with a capital T. Fix the regex, not the readme. A version of `unknown` makes `pup zip-name` drop the
  version from the filename entirely, so the zip uploads as `<zip_name>.zip` and the bot never finds it.
- `pup zip-name "$(pup get-version --dev)"` matches what the bot predicts. Both should be
  `<zip_name>.<version>-dev-<timestamp>-<hash>`.
- Run the workflow manually from the Actions tab, `production: no`, and confirm the run uploads to S3
  and posts to Slack when given a channel and thread.
- If the repo ships a POT, download the run's artifact and confirm `languages/<slug>.pot` is present and
  roughly the size of the one in the current zip. Presence alone isn't enough — an empty or truncated POT
  looks like success until a translator opens it.
- Ask the bot for a zip and confirm it dispatches `zip.yml` rather than `generate-zip.yml`.

## Phase 4 — open the PR

Keep `generate-zip.yml` in the same PR. It's the rollback: deleting `zip.yml` restores the old path with
no other change. Remove it in a follow-up once a release has gone out on the new workflow.

In the PR description, list which prerequisites you created, which secrets a human still has to set, and
paste the `pup zip-name` output alongside the filename the bot predicts.
