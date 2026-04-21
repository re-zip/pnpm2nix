{
  lib,
  stdenv,
  nodejs,
  pkg-config,
  callPackage,
  writeText,
  runCommand,
  ...
}:
with builtins;
with lib;
with callPackage ./lockfile.nix {}; let
  nodePkg = nodejs;
  pkgConfigPkg = pkg-config;

  # Build the pnpm content-addressable store as a separate derivation.
  # Inputs: the lockfile (via processLockfile). Deduped across callers that
  # pass the same lockfile, since the derivation name is fixed.
  mkPnpmStore = {
    pnpmLockYaml,
    registry ? "https://registry.npmjs.org",
    noDevDependencies ? false,
    nodejs ? nodePkg,
    pnpm ? nodejs.pkgs.pnpm,
  }: let
    processResult = processLockfile {
      inherit registry noDevDependencies;
      lockfile = pnpmLockYaml;
    };
    tarballs = unique processResult.dependencyTarballs;
  in
    stdenv.mkDerivation {
      name = "pnpm-store";
      nativeBuildInputs = [nodejs pnpm];
      # Pass the tarball list via a file to avoid ARG_MAX on huge monorepos.
      depsList = concatStringsSep "\n" tarballs;
      passAsFile = ["depsList"];
      dontUnpack = true;
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        mkdir -p $out
        store=$(pnpm store path)
        mkdir -p $(dirname $store)
        [ -e "$store" ] && rm -rf "$store"
        ln -s $out "$store"
        xargs -a "$depsListPath" -d '\n' -n 200 pnpm store add
        runHook postBuild
      '';
      installPhase = "true";
      passthru = {
        inherit tarballs;
        patchedLockfile = processResult.patchedLockfile;
        patchedLockfileYaml = writeText "pnpm-lock.yaml" (toJSON processResult.patchedLockfile);
      };
    };

  # Build node_modules as a separate derivation. Source is ONLY package.jsons,
  # workspace.yaml, and the patched lockfile — no app source code. Result is
  # reused across every app build in a workspace.
  mkPnpmNodeModules = {
    workspace ? null,
    components ? [],
    packageJSON,
    componentPackageJSONs ? [],
    pnpmLockYaml,
    pnpmWorkspaceYaml ? null,
    extraNodeModuleSources ? [],
    registry ? "https://registry.npmjs.org",
    nodejs ? nodePkg,
    pnpm ? nodejs.pkgs.pnpm,
    noDevDependencies ? false,
    installEnv ? {},
    copyPnpmStore ? true,
    pname ? "workspace",
    pnpmStore ? null,
  }: let
    forEachConcat = f: xs: concatStringsSep "\n" (map f xs);
    forEachComponent = f: forEachConcat f components;

    packageFiles =
      [{ name = "package.json"; value = packageJSON; }]
      ++ componentPackageJSONs
      ++ (
        if pnpmWorkspaceYaml == null
        then []
        else [{ name = "pnpm-workspace.yaml"; value = pnpmWorkspaceYaml; }]
      )
      ++ extraNodeModuleSources;

    store =
      if pnpmStore != null
      then pnpmStore
      else
        mkPnpmStore {
          inherit pnpmLockYaml registry noDevDependencies nodejs pnpm;
        };
    patchedLockfileYaml = store.passthru.patchedLockfileYaml;
  in
    stdenv.mkDerivation {
      name = "${pname}-node-modules";
      nativeBuildInputs = [nodejs pnpm];

      # pnpm's node_modules contains symlinks to @repo/* package paths that
      # only exist once the source tree is layered in during the app build.
      # They're "broken" in isolation but correct at consumption time.
      # Skip the whole fixupPhase (shebang patching + symlink checks) —
      # rewriting shebangs inside node_modules just churns hashes without
      # fixing anything that wasn't already working in the sandbox.
      dontFixup = true;

      unpackPhase = concatStringsSep "\n" (
        [(forEachComponent (c: ''mkdir -p "${c}"''))]
        ++ map
          (v: let
            nv =
              if isAttrs v
              then v
              else {
                name = ".";
                value = v;
              };
          in ''cp -v "${nv.value}" "${nv.name}"'')
          ([{ name = "pnpm-lock.yaml"; value = patchedLockfileYaml; }] ++ packageFiles)
      );

      buildPhase = ''
        export HOME=$NIX_BUILD_TOP
        runHook preBuild

        store=$(pnpm store path)
        mkdir -p $(dirname $store)

        cp -f ${patchedLockfileYaml} pnpm-lock.yaml

        ${
          if !copyPnpmStore
          then ''ln -s ${store} "$(pnpm store path)"''
          else ''
            cp -RL ${store} "$(pnpm store path)"
            chmod -R u+w "$(pnpm store path)"
          ''
        }

        ${concatStringsSep "\n" (
          mapAttrsToList (n: v: ''export ${n}="${v}"'') installEnv
        )}

        pnpm install --stream ${optionalString noDevDependencies "--prod "}--frozen-lockfile --offline
        runHook postBuild
      '';

      # cp -a preserves pnpm's symlinks (root node_modules/.pnpm/* <- component
      # node_modules/.pnpm/*). cp -r would dereference them.
      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp -a node_modules $out/node_modules
        ${forEachComponent (c: ''
          if [ -d "${c}/node_modules" ]; then
            mkdir -p "$out/${c}"
            cp -a "${c}/node_modules" "$out/${c}/node_modules"
          fi
        '')}
        runHook postInstall
      '';

      passthru = {
        inherit (store.passthru) patchedLockfileYaml patchedLockfile;
        pnpmStore = store;
      };
    };

  mkPnpmPackage = {
    workspace ? null,
    components ? [],
    src ?
      if (workspace != null && components != [])
      then workspace
      else null,
    packageJSON ? src + "/package.json",
    componentPackageJSONs ?
      map (c: {
        name = "${c}/package.json";
        value = src + "/${c}/package.json";
      })
      components,
    pnpmLockYaml ? src + "/pnpm-lock.yaml",
    pnpmWorkspaceYaml ? (
      if workspace == null
      then null
      else workspace + "/pnpm-workspace.yaml"
    ),
    pname ? (fromJSON (readFile packageJSON)).name,
    version ? (fromJSON (readFile packageJSON)).version or null,
    name ?
      if version != null
      then "${pname}-${version}"
      else pname,
    registry ? "https://registry.npmjs.org",
    script ? "build",
    distDir ? "dist",
    distDirs ? (
      if workspace == null
      then [distDir]
      else (map (c: "${c}/dist") components)
    ),
    distDirIsOut ? true,
    installNodeModules ? false,
    installPackageFiles ? false,
    installInPlace ? false,
    installEnv ? {},
    buildEnv ? {},
    noDevDependencies ? false,
    extraNodeModuleSources ? [],
    copyPnpmStore ? true,
    copyNodeModules ? false,
    extraBuildInputs ? [],
    extraNativeBuildInputs ? [],
    # Optional injection points: when provided, reuse these derivations instead
    # of computing fresh ones. mkPnpmWorkspace uses this to share deps across
    # many apps.
    nodeModules ? null,
    pnpmStore ? null,
    nodejs ? nodePkg,
    pnpm ? nodejs.pkgs.pnpm,
    pkg-config ? pkgConfigPkg,
    ...
  } @ attrs: let
    isWorkspace = workspace != null && components != [];
    forEachConcat = f: xs: concatStringsSep "\n" (map f xs);
    forEachComponent = f: forEachConcat f components;

    nativeBuildInputs =
      [nodejs pnpm pkg-config]
      ++ extraNativeBuildInputs;
    buildInputs = extraBuildInputs;

    computedNodeModuleSources =
      (
        if pnpmWorkspaceYaml == null
        then []
        else [{ name = "pnpm-workspace.yaml"; value = pnpmWorkspaceYaml; }]
      )
      ++ extraNodeModuleSources;

    packageFilesWithoutLockfile =
      [{ name = "package.json"; value = packageJSON; }]
      ++ componentPackageJSONs
      ++ computedNodeModuleSources;

    nodeModulesDirs =
      if isWorkspace
      then ["node_modules"] ++ (map (c: "${c}/node_modules") components)
      else ["node_modules"];

    computedDistFiles = let
      packageFileNames =
        ["pnpm-lock.yaml"]
        ++ map ({name, ...}: name) packageFilesWithoutLockfile;
    in
      distDirs
      ++ optionals installNodeModules nodeModulesDirs
      ++ optionals installPackageFiles packageFileNames;

    filterString =
      concatStringsSep " " (
        ["--recursive" "--stream"]
        ++ map (c: "--filter ./${c}") components
      )
      + " ";

    buildScripts = ''
      pnpm run ${optionalString isWorkspace filterString}${script}
    '';

    computedDistDirIsOut = length distDirs == 1 && distDirIsOut;

    resolvedStore =
      if pnpmStore != null
      then pnpmStore
      else
        mkPnpmStore {
          inherit pnpmLockYaml registry noDevDependencies nodejs pnpm;
        };

    computedNodeModules = mkPnpmNodeModules {
      inherit workspace components packageJSON componentPackageJSONs
              pnpmLockYaml pnpmWorkspaceYaml extraNodeModuleSources
              registry nodejs pnpm noDevDependencies installEnv
              copyPnpmStore pname;
      pnpmStore = resolvedStore;
    };

    effectiveNodeModules =
      if nodeModules != null
      then nodeModules
      else computedNodeModules;

    patchedLockfileYaml = resolvedStore.passthru.patchedLockfileYaml;

    # Per-dir layering: either symlink (read-only, fast) or reflink-cp
    # (writable, almost as fast on CoW filesystems).
    layerNodeModules = dir:
      if copyNodeModules
      then ''
        cp -aT --reflink=auto ${effectiveNodeModules}/${dir} ${dir}
        chmod -R u+w ${dir}
      ''
      else ''ln -s ${effectiveNodeModules}/${dir} ${dir}'';
  in
    stdenv.mkDerivation (
      recursiveUpdate
      rec {
        inherit src name nativeBuildInputs buildInputs;

        postUnpack = ''
          ${optionalString (pnpmWorkspaceYaml != null) ''
            cp ${pnpmWorkspaceYaml} pnpm-workspace.yaml
          ''}
          ${forEachComponent (c: ''mkdir -p "${c}"'')}
        '';

        configurePhase = ''
          export HOME=$NIX_BUILD_TOP
          export npm_config_nodedir=${nodejs}

          runHook preConfigure

          ${
            if installInPlace
            then computedNodeModules.buildPhase
            else forEachConcat layerNodeModules nodeModulesDirs
          }

          cp -f ${patchedLockfileYaml} pnpm-lock.yaml

          runHook postConfigure
        '';

        buildPhase = ''
          ${concatStringsSep "\n" (
            mapAttrsToList (n: v: ''export ${n}="${v}"'') buildEnv
          )}

          runHook preBuild

          ${buildScripts}

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          ${
            if computedDistDirIsOut
            then ''
              mkdir -p $out
              cp -r ${head distDirs}/. $out/
            ''
            else ''
              mkdir -p $out
              ${forEachConcat (d: ''cp -r --parents ${d} $out'') computedDistFiles}
            ''
          }

          runHook postInstall
        '';

        passthru = {
          inherit attrs patchedLockfileYaml;
          nodeModules = effectiveNodeModules;
          pnpmStore = resolvedStore;
          patchedLockfile = resolvedStore.passthru.patchedLockfile;
        };
      }
      (attrs
        // {
          extraNodeModuleSources = null;
          installEnv = null;
          buildEnv = null;
          nodeModules = null;
          pnpmStore = null;
        })
    );

  # Convenience function for multi-app pnpm workspaces. Builds one shared
  # nodeModules derivation and reuses it across every app. Each app's source
  # is filtered to exclude other apps' directories, so touching one app does
  # not invalidate the others.
  #
  # apps :: [{ name; path; script?; distDir?; version?; buildEnv?;
  #            extraNativeBuildInputs?; extraArgs?; }]
  # packages :: [String]  # component paths like "packages/foo"
  mkPnpmWorkspace = {
    workspace,
    apps,
    packages ? [],
    pnpmLockYaml ? workspace + "/pnpm-lock.yaml",
    pnpmWorkspaceYaml ? workspace + "/pnpm-workspace.yaml",
    packageJSON ? workspace + "/package.json",
    registry ? "https://registry.npmjs.org",
    nodejs ? nodePkg,
    pnpm ? nodejs.pkgs.pnpm,
    noDevDependencies ? false,
    installEnv ? {},
    buildEnv ? {},
    extraNativeBuildInputs ? [],
    extraNodeModuleSources ? [],
    isolateApps ? true,
    appSrc ? null,
    copyNodeModules ? true,
    copyPnpmStore ? true,
  }: let
    appPaths = map (a: a.path) apps;
    allComponents = appPaths ++ packages;
    componentPackageJSONs = map (c: {
      name = "${c}/package.json";
      value = workspace + "/${c}/package.json";
    }) allComponents;

    sharedStore = mkPnpmStore {
      inherit pnpmLockYaml registry noDevDependencies nodejs pnpm;
    };

    sharedNodeModules = mkPnpmNodeModules {
      inherit workspace packageJSON componentPackageJSONs
              pnpmLockYaml pnpmWorkspaceYaml registry nodejs pnpm
              noDevDependencies installEnv copyPnpmStore
              extraNodeModuleSources;
      components = allComponents;
      pnpmStore = sharedStore;
    };

    # Exclude other apps from a given app's source tree so their changes
    # don't invalidate this app's build cache. Shared `packages/*` are kept.
    defaultAppSrc = appName:
      lib.fileset.toSource {
        root = workspace;
        fileset = lib.fileset.difference
          workspace
          (lib.fileset.unions (
            map (a: workspace + "/${a.path}")
              (filter (a: a.name != appName) apps)
          ));
      };

    resolveAppSrc = appName:
      if appSrc != null
      then appSrc appName
      else if isolateApps
      then defaultAppSrc appName
      else workspace;

    mkApp = app: let
      # Only this app + shared packages — never other apps. Keeps pnpm's
      # --filter scope tight and restricts node_modules layering to what the
      # app actually needs, even though sharedNodeModules contains every
      # component's node_modules directory.
      appComponents = [app.path] ++ packages;
    in
      mkPnpmPackage ({
        inherit pnpmLockYaml pnpmWorkspaceYaml packageJSON registry nodejs pnpm
                noDevDependencies installEnv copyPnpmStore copyNodeModules;
        workspace = workspace;
        src = resolveAppSrc app.name;
        components = appComponents;
        pname = app.name;
        version = app.version or "0.0.0";
        script = app.script or "build";
        distDir = "${app.path}/${app.distDir or "dist"}";
        distDirs = ["${app.path}/${app.distDir or "dist"}"];
        distDirIsOut = true;
        extraNativeBuildInputs =
          extraNativeBuildInputs ++ (app.extraNativeBuildInputs or []);
        buildEnv = buildEnv // (app.buildEnv or {});
        nodeModules = sharedNodeModules;
        pnpmStore = sharedStore;
      }
      // (app.extraArgs or {}));
  in {
    apps = listToAttrs (map (a: {
        name = a.name;
        value = mkApp a;
      })
      apps);
    nodeModules = sharedNodeModules;
    pnpmStore = sharedStore;
    patchedLockfileYaml = sharedStore.passthru.patchedLockfileYaml;
  };
in {
  inherit mkPnpmPackage mkPnpmWorkspace mkPnpmNodeModules mkPnpmStore;
}
