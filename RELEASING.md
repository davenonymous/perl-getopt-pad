# Releasing Getopt::Pad to CPAN

This dist uses plain `ExtUtils::MakeMaker` plus
[`cpan-upload`](https://metacpan.org/pod/cpan-upload) (from
`CPAN::Uploader`). No Dist::Zilla, no Minilla, no surprises.

## Per-release checklist

1. Make sure the working tree is clean and on `master`:

   ```sh
   git status
   git pull --ff-only
   ```

2. Bump `$VERSION`. Every module under `lib/` carries its own
   `our $VERSION` line and they must all agree; `make release` refuses
   to run otherwise (`make version-check` runs that guard alone). Bump
   them in one go:

   ```sh
   perl -pi -e "s/^(\s*our \\\$VERSION\s*=\s*)'[^']*'/\${1}'0.02'/" $(git ls-files 'lib/*.pm')
   ```

3. Update `Changes`: replace the date on the new version's heading and
   add bullet points describing the changes since the last release.

4. Keep `README.md` in step with the pod in `lib/Getopt/Pad.pm`. It is
   written by hand and ships in the dist, so review it whenever the
   synopsis, the feature list, the examples, or the prerequisites
   changed.

5. Sanity-build from a clean slate:

   ```sh
   make distclean 2>/dev/null || true
   perl Makefile.PL
   make
   make test
   ```

6. Commit the version bump and `Changes` entry, push it and wait for
   CI to pass on that commit. `make release` refuses to run on a dirty
   tree, so the commit has to happen first anyway:

   ```sh
   git commit -am "Release v$(perl -Ilib -MGetopt::Pad -e 'print $Getopt::Pad::VERSION')"
   git push
   gh run watch --exit-status \
       "$(gh run list --workflow ci.yml --commit "$(git rev-parse HEAD)" --limit 1 --json databaseId --jq '.[0].databaseId')"
   ```

   If `gh run list` finds no run yet, wait a few seconds: GitHub
   creates it shortly after the push. Upload only when every job is
   green; `make release` refuses to upload otherwise. If one fails,
   fix the cause, commit, push and watch again.

7. Cut and upload the release:

   ```sh
   make release
   ```

   The `release` target:

   - Refuses to proceed if any module's `$VERSION` differs from the
     one in `lib/Getopt/Pad.pm`.
   - Refuses to proceed if the git working tree is dirty.
   - Refuses to proceed if a tag `v$(VERSION)` already exists.
   - Refuses to proceed unless the GitHub CI run of `HEAD` has passed
     (`make ci-check`, which needs an authenticated `gh`).
   - Runs `make disttest` (builds the dist directory, configures it,
     and runs its tests - this is what catches missing `MANIFEST`
     entries before they reach CPAN).
   - Runs `make dist` in a second sub-make to build the tarball from
     a fresh dist directory (`disttest` alone does not create one,
     and running both as prerequisites of a single target would pack
     the `blib/` left behind by `disttest`).
   - Refuses to upload if the tarball is missing or contains build
     artefacts (`blib/`, `Makefile`, `MYMETA.*`, `pm_to_blib`).
     PAUSE does not index such tarballs.
   - Runs `cpan-upload` on the freshly built tarball.

8. Tag and push:

   ```sh
   git tag -a "v$(perl -Ilib -MGetopt::Pad -e 'print $Getopt::Pad::VERSION')" \
          -m "Release v$(perl -Ilib -MGetopt::Pad -e 'print $Getopt::Pad::VERSION')"
   git push --follow-tags
   ```

   The tag must be annotated (`-a`): `git push --follow-tags` only
   pushes annotated tags, so a lightweight tag would silently stay
   local.

9. Wait ~1 hour, then verify on
   [MetaCPAN](https://metacpan.org/dist/Getopt-Pad). PAUSE also
   mails an indexer report; "no modules will be indexed" there means
   the release is broken and needs a bumped re-release.

## MANIFEST

`MANIFEST` is checked in. After adding or removing a file, regenerate
it and review the diff before committing:

```sh
perl Makefile.PL
make manifest
git diff MANIFEST
```

`MANIFEST.SKIP` keeps the maintainer-only files (this document,
`CONTEXT.md`, `.claude/`, CI config) out of the dist.

## Recovery

- **Upload failed mid-way.** `cpan-upload` is idempotent against PAUSE
  re-uploads of the *same* tarball; just run `make release` again.
- **Uploaded a broken release.** You have 72 hours to delete it from
  PAUSE via the web UI (`https://pause.perl.org/` -> "Delete
  Files"). After that it's permanent in the BackPAN archive. Either
  way, **never reuse a version number** - bump and re-release.
- **Forgot to bump `$VERSION`.** The `release` target's "tag already
  exists" guard will catch this on the second run, but the tarball
  will already exist locally. Delete it (`rm Getopt-Pad-*.tar.gz`),
  bump the version, and start over.

## Notes on Object::Pad

- The modules under `lib/` declare their packages with Object::Pad's
  `class` keyword instead of `package`. PAUSE's indexer recognises
  `class NAME` once it has seen a `use Object::Pad` line in the file,
  so every class file must keep that line above its `class` statement.
- `Module::Metadata` does not recognise `class`, so tools built on it
  (`module-info`, the stock META `provides` generators) report those
  files as package `main`. `Makefile.PL` therefore builds the
  `provides` map itself by scanning `lib/` for `package`/`class`
  lines and `$VERSION`; it dies on a module missing either, so a new
  module without a `$VERSION` line fails at `perl Makefile.PL`.
- `Object::Pad` is XS, so `cpanm --installdeps .` needs a C compiler on
  the build host. The dist itself is pure Perl.
