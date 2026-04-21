# pnpm2nix

Build pnpm packages with Nix — with caching that actually works for monorepos.

This fork (based on [nzbr/pnpm2nix-nzbr](https://github.com/nzbr/pnpm2nix-nzbr), taking inspiration from [FliegendeWurst/pnpm2nix-nzbr](https://github.com/FliegendeWurst/pnpm2nix-nzbr) and [jw910731/pnpm2nix-nzbr](https://github.com/jw910731/pnpm2nix-nzbr)) restructures the build into independent, finely-cacheable layers and adds a `mkPnpmWorkspace` convenience wrapper for multi-app workspaces.

## Why this fork

The upstream `mkPnpmPackage` builds dependencies and source together in one derivation. Any source edit reinvalidates dependency installation; any dep bump rebuilds the whole ~GB-scale pnpm store from scratch. This fork splits the work into four derivations:

| derivation         | depends on                           | when it rebuilds                            |
| ------------------ | ------------------------------------ | ------------------------------------------- |
| per-tarball shard  | one fetchurl tarball                 | only that dep's version changes             |
| `mkPnpmStore`      | all shards (via `symlinkJoin`)       | any shard rebuild — but merge is cheap      |
| `mkPnpmNodeModules`| shards + `package.json` files        | dep graph changes (add/remove/bump)         |
| `mkPnpmPackage`    | source code + `nodeModules` layer    | source changes                              |

Concretely: bumping `react` rebuilds one shard (~1s) plus the symlinkJoin (~seconds). Editing one file in one app rebuilds only that app.

## Usage

Expose the overlay to your pkgs:

```nix
{
  inputs.pnpm2nix.url = "github:re-zip/pnpm2nix";

  outputs = { nixpkgs, pnpm2nix, ... }: let
    pkgs = import nixpkgs {
      system = "x86_64-linux";
      overlays = [ pnpm2nix.overlays.default ];
    };
  in {
    # ... use pkgs.mkPnpmPackage / pkgs.mkPnpmWorkspace here
  };
}
```

Or `pkgs.callPackage /path/to/derivation.nix {}` to get the function set directly.

### Single-package build

```nix
pkgs.mkPnpmPackage {
  src = ./.;
}
```

### Workspace build (recommended for monorepos)

One call builds every app in a pnpm workspace, sharing a single dependency layer:

```nix
pkgs.mkPnpmWorkspace {
  workspace = ./.;
  apps = [
    { name = "web";     path = "apps/web"; }
    { name = "admin";   path = "apps/admin"; script = "build:prod"; }
    { name = "worker";  path = "apps/worker";
      extraNativeBuildInputs = [ pkgs.jq pkgs.wrangler ]; }
  ];
  packages = [ "packages/utils" "packages/ui" ];
}
```

Returns:

```nix
{
  apps.web     = <derivation>;  # apps/web/dist → $out
  apps.admin   = <derivation>;
  apps.worker  = <derivation>;
  nodeModules  = <derivation>;  # the shared deps layer, handy for debugging
  pnpmStore    = <derivation>;  # the sharded pnpm store
  patchedLockfileYaml = <path>;
}
```

By default `mkPnpmWorkspace` filters each app's source to exclude the other apps' directories, so editing `apps/web` leaves `apps/admin`'s derivation hash untouched. Shared `packages/*` are kept in every app's source (changes there invalidate every consumer, as they should).

## `mkPnpmPackage` arguments

In addition to everything `stdenv.mkDerivation` accepts:

| argument                 | description                                                                         | default                        |
| ------------------------ | ----------------------------------------------------------------------------------- | ------------------------------ |
| `src`                    | Path to the package sources                                                         | `workspace` when in workspace mode |
| `workspace`              | Workspace root — enables workspace mode when set with `components`                  | `null`                         |
| `components`             | Component paths (e.g. `[ "apps/foo" "packages/bar" ]`) for workspace mode           | `[]`                           |
| `packageJSON`            | Override the path to the root `package.json`                                        | `${src}/package.json`          |
| `componentPackageJSONs`  | List of `{ name; value; }` pairs for per-component `package.json` paths             | derived from `components`      |
| `pnpmLockYaml`           | Override the path to `pnpm-lock.yaml`                                               | `${src}/pnpm-lock.yaml`        |
| `pnpmWorkspaceYaml`      | Override the path to `pnpm-workspace.yaml`                                          | `${workspace}/pnpm-workspace.yaml` |
| `pname`, `version`, `name` | Naming overrides                                                                 | read from `package.json`       |
| `nodejs`                 | The nodejs package that is used                                                     | `pkgs.nodejs`                  |
| `pnpm`                   | The pnpm package that is used                                                       | `nodejs.pkgs.pnpm`             |
| `registry`               | Registry to resolve tarballs against                                                | `https://registry.npmjs.org`   |
| `script`                 | The npm script that is executed                                                     | `build`                        |
| `distDir`                | Directory copied to `$out` after build                                              | `dist`                         |
| `distDirs`               | Multiple distDirs (workspace mode only)                                             | `map (c: "${c}/dist") components` |
| `distDirIsOut`           | When a single distDir, copy its contents to `$out` root instead of `$out/${distDir}` | `true`                        |
| `nodeModules`            | Inject a pre-built `nodeModules` derivation — skips internal computation            | `null`                         |
| `pnpmStore`              | Inject a pre-built `pnpmStore` derivation — skips internal computation              | `null`                         |
| `installInPlace`         | Run `pnpm install` directly in the source derivation instead of in a separate layer | `false`                        |
| `installEnv`             | Environment vars set during `pnpm install`                                          | `{}`                           |
| `buildEnv`               | Environment vars set during the build script                                        | `{}`                           |
| `noDevDependencies`      | Install only `dependencies`, not `devDependencies`                                  | `false`                        |
| `extraNodeModuleSources` | Additional files placed in the node_modules build tree (e.g. a custom `.npmrc`)     | `[]`                           |
| `copyPnpmStore`          | Copy the pnpm store into the build directory instead of linking it                  | `true`                         |
| `copyNodeModules`        | Copy `node_modules` into the build directory (reflink-aware cp) instead of linking  | `false`                        |
| `extraBuildInputs`       | Entries appended to `buildInputs`                                                   | `[]`                           |
| `extraNativeBuildInputs` | Entries appended to `nativeBuildInputs`                                             | `[]`                           |

## `mkPnpmWorkspace` arguments

| argument                 | description                                                                         | default                        |
| ------------------------ | ----------------------------------------------------------------------------------- | ------------------------------ |
| `workspace`              | Workspace root path (required)                                                      |                                |
| `apps`                   | List of `{ name; path; script?; distDir?; version?; buildEnv?; extraNativeBuildInputs?; extraArgs?; }` | |
| `packages`               | Shared component paths (e.g. `[ "packages/foo" ]`)                                  | `[]`                           |
| `pnpmLockYaml`           | Override the path to `pnpm-lock.yaml`                                               | `${workspace}/pnpm-lock.yaml`  |
| `pnpmWorkspaceYaml`      | Override the path to `pnpm-workspace.yaml`                                          | `${workspace}/pnpm-workspace.yaml` |
| `packageJSON`            | Override the path to the root `package.json`                                        | `${workspace}/package.json`    |
| `registry`, `nodejs`, `pnpm`, `noDevDependencies`, `installEnv`, `buildEnv`, `copyNodeModules`, `copyPnpmStore` | Same as `mkPnpmPackage` | |
| `extraNativeBuildInputs` | Appended to every app's `nativeBuildInputs`                                         | `[]`                           |
| `extraNodeModuleSources` | Sources placed in both the shared deps layer AND each app build tree                | `[]`                           |
| `isolateApps`            | Filter each app's source to exclude the other apps' directories                     | `true`                         |
| `appSrc`                 | Override fn `appName -> src` (takes precedence over `isolateApps`)                  | `null`                         |

## `mkPnpmStore` arguments

Exposed for advanced use: build just the pnpm store without any node_modules / app layer.

| argument                 | description                                                                         | default                        |
| ------------------------ | ----------------------------------------------------------------------------------- | ------------------------------ |
| `pnpmLockYaml`           | The lockfile to resolve tarballs from (required)                                    |                                |
| `registry`               | Registry base URL                                                                   | `https://registry.npmjs.org`   |
| `noDevDependencies`      | Skip `dev: true` entries                                                            | `false`                        |
| `sharded`                | Build one derivation per tarball + `symlinkJoin` them (vs. one monolithic store)    | `true`                         |
| `nodejs`, `pnpm`         | Toolchain overrides                                                                 | defaults                       |

### Why sharded is the default

With `sharded = true`, each of the ~N tarballs in your lockfile gets its own tiny derivation, and the final store is a `symlinkJoin` of all of them. The merge is safe because pnpm's store layout is fully content-addressed:

- Top-level entries are named `file+<encoded-tarball-path>/` — unique per tarball.
- Shared `files/<hash-prefix>/<hash>` and `index/<hash-prefix>/<hash>` subdirs are SHA-keyed. When two tarballs contain an identical file (e.g. a common `LICENSE`), both shards point to the same relative path with the same content, and `lndir` (inside `symlinkJoin`) collapses them.

Trade-off: the **first** build pays pnpm's startup cost per tarball (~5-10s overhead each), so a 2000-tarball lockfile takes 10-15 minutes the first time. Every subsequent build reuses shard caches, and a one-dep bump only rebuilds that one shard. For CI setups that share a Nix store across runs this is a clear win; for always-cold-cache machines, pass `sharded = false` to get the monolithic behaviour (single `pnpm store add` call with every tarball, ~3-5 minutes on a fresh build but no incremental granularity afterwards).

## `mkPnpmNodeModules` arguments

Exposed for advanced use: build just the `node_modules` layer.

| argument                 | description                                                                         | default                        |
| ------------------------ | ----------------------------------------------------------------------------------- | ------------------------------ |
| `packageJSON`            | Path to the root `package.json` (required)                                          |                                |
| `pnpmLockYaml`           | Path to `pnpm-lock.yaml` (required)                                                 |                                |
| `componentPackageJSONs`  | `{ name; value; }` pairs for workspace components                                   | `[]`                           |
| `pnpmWorkspaceYaml`      | Workspace config path                                                               | `null`                         |
| `extraNodeModuleSources` | Extra files placed in the build tree before `pnpm install`                          | `[]`                           |
| `pnpmStore`              | Reuse an existing store derivation (avoids re-resolving)                            | computed internally            |
| `registry`, `noDevDependencies`, `installEnv`, `copyPnpmStore`, `nodejs`, `pnpm`, `pname` | Same as `mkPnpmStore`    | |

## License

ISC. See [LICENSE](LICENSE).
