{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    getExe
    getExe'
    literalExpression
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optional
    types
    ;

  cfg = config.services.buildbarn;
  inherit (cfg) ports;

  allow = {
    allow = { };
  };

  grpcClient = address: { grpc.client.address = address; };

  blobstoreFor = storage: {
    contentAddressableStorage = grpcClient storage;
    actionCache.completenessChecking = {
      backend = grpcClient storage;
      maximumTotalTreeSizeBytes = 64 * 1024 * 1024;
    };
  };

  maximumMessageSizeBytes = 16 * 1024 * 1024;

  mkConfig = name: value: pkgs.writeText "buildbarn-${name}.json" (builtins.toJSON value);

  gib = n: n * 1024 * 1024 * 1024;

  serviceConfig = {
    User = "buildbarn";
    Group = "buildbarn";
    Restart = "on-failure";
    LimitNOFILE = 1048576;
  };

  mkPort =
    default: description:
    mkOption {
      type = types.port;
      inherit default description;
    };

  runnerModule =
    { config, ... }:
    {
      options = {
        pool = mkOption {
          type = types.str;
          example = "java16";
          description = "Pool platform property this runner serves. Soong's reclient rules send java16 for javac, turbine, R8, D8 and metalava.";
        };

        platform = mkOption {
          type = types.attrsOf types.str;
          default = {
            Pool = config.pool;
            "container-image" = cfg.containerImage;
          };
          defaultText = literalExpression ''
            {
              Pool = pool;
              "container-image" = config.services.buildbarn.containerImage;
            }
          '';
          description = "Platform properties this runner advertises.";
        };

        concurrency = mkOption {
          type = types.ints.positive;
          default = 2;
          description = "Number of actions this runner executes in parallel.";
        };

        memoryMax = mkOption {
          type = types.str;
          default = "16G";
          description = "systemd MemoryMax of this runner.";
        };

        nice = mkOption {
          type = types.ints.between (-20) 19;
          default = cfg.worker.nice;
          defaultText = literalExpression "config.services.buildbarn.worker.nice";
          description = "Nice value of this runner.";
        };
      };
    };

  server =
    let
      bbStorage = getExe cfg.storagePackage;
      bbScheduler = "${cfg.remoteExecutionPackage}/bin/bb_scheduler";
      localStorage = "127.0.0.1:${toString ports.storage}";
      inherit (cfg.server) storageDir;

      localStore = dir: keySize: blockSize: newBlocks: {
        local = {
          keyLocationMapOnBlockDevice.file = {
            path = "${storageDir}/${dir}/key_location_map";
            sizeBytes = keySize;
          };
          keyLocationMapMaximumGetAttempts = 16;
          keyLocationMapMaximumPutAttempts = 64;
          oldBlocks = 8;
          currentBlocks = 24;
          inherit newBlocks;
          blocksOnBlockDevice = {
            source.file = {
              path = "${storageDir}/${dir}/blocks";
              sizeBytes = blockSize;
            };
            spareBlocks = 3;
          };
          persistent = {
            stateDirectoryPath = "${storageDir}/${dir}/persistent_state";
            minimumEpochInterval = "300s";
          };
        };
      };

      storageConfig = mkConfig "storage" {
        grpcServers = [
          {
            listenAddresses = [ ":${toString ports.storage}" ];
            authenticationPolicy = allow;
          }
        ];
        inherit maximumMessageSizeBytes;
        contentAddressableStorage = {
          backend = localStore "storage-cas" (gib 1) (gib cfg.server.casSize) 3;
          getAuthorizer = allow;
          putAuthorizer = allow;
          findMissingAuthorizer = allow;
        };
        actionCache = {
          backend = localStore "storage-ac" (64 * 1024 * 1024) (gib cfg.server.actionCacheSize) 1;
          getAuthorizer = allow;
          putAuthorizer = allow;
        };
      };

      schedulerConfig = mkConfig "scheduler" {
        adminHttpServers = [
          {
            listenAddresses = [ "127.0.0.1:${toString ports.schedulerAdmin}" ];
            authenticationPolicy = allow;
          }
        ];
        clientGrpcServers = [
          {
            listenAddresses = [ "127.0.0.1:${toString ports.scheduler}" ];
            authenticationPolicy = allow;
          }
        ];
        workerGrpcServers = [
          {
            listenAddresses = [ ":${toString ports.schedulerWorkers}" ];
            authenticationPolicy = allow;
          }
        ];
        browserUrl = "http://127.0.0.1:${toString ports.schedulerAdmin}";
        contentAddressableStorage = grpcClient localStorage;
        inherit maximumMessageSizeBytes;
        executeAuthorizer = allow;
        modifyDrainsAuthorizer = allow;
        killOperationsAuthorizer = allow;
        synchronizeAuthorizer = allow;
        actionRouter.simple = {
          platformKeyExtractor.action = { };
          invocationKeyExtractors = [
            { correlatedInvocationsId = { }; }
            { toolInvocationId = { }; }
          ];
          initialSizeClassAnalyzer = {
            defaultExecutionTimeout = "1800s";
            maximumExecutionTimeout = "7200s";
          };
        };
        platformQueueWithNoWorkersTimeout = "900s";
      };

      frontendConfig = mkConfig "frontend" {
        grpcServers = [
          {
            listenAddresses = [ ":${toString ports.frontend}" ];
            authenticationPolicy = allow;
          }
        ];
        schedulers."".endpoint.address = "127.0.0.1:${toString ports.scheduler}";
        inherit maximumMessageSizeBytes;
        contentAddressableStorage = {
          backend = grpcClient localStorage;
          getAuthorizer = allow;
          putAuthorizer = allow;
          findMissingAuthorizer = allow;
        };
        actionCache = {
          backend = (blobstoreFor localStorage).actionCache;
          getAuthorizer = allow;
          putAuthorizer = allow;
        };
        executeAuthorizer = allow;
      };

      service = exec: after: {
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ] ++ after;
        wants = [ "network-online.target" ];
        serviceConfig = serviceConfig // {
          ExecStart = exec;
        };
      };
    in
    {
      systemd.tmpfiles.rules = optional (
        storageDir != cfg.stateDir
      ) "d ${storageDir} 0750 buildbarn buildbarn -";

      systemd.services = {
        buildbarn-storage = lib.recursiveUpdate (service "${bbStorage} ${storageConfig}" [ ]) {
          serviceConfig = {
            ExecStartPre = "${getExe' pkgs.coreutils "mkdir"} -p ${
              lib.concatMapStringsSep " " (dir: "${storageDir}/${dir}/persistent_state") [
                "storage-cas"
                "storage-ac"
              ]
            }";
            UMask = "0027";
          };
        };
        buildbarn-scheduler = service "${bbScheduler} ${schedulerConfig}" [ "buildbarn-storage.service" ];
        buildbarn-frontend = service "${bbStorage} ${frontendConfig}" [
          "buildbarn-storage.service"
          "buildbarn-scheduler.service"
        ];
      };

      networking.firewall.allowedTCPPorts = mkIf cfg.server.openFirewall [
        ports.frontend
        ports.storage
        ports.schedulerWorkers
      ];
    };

  worker =
    let
      bb = cfg.remoteExecutionPackage;
      inherit (cfg.worker) workDir;
      blobstore = blobstoreFor "${cfg.worker.server}:${toString ports.storage}";

      runnerEnv = pkgs.buildFHSEnv {
        name = "buildbarn-runner-env";
        targetPkgs = _: cfg.worker.runnerPackages;
        runScript = "${bb}/bin/bb_runner";
      };

      runners = [
        {
          unit = "buildbarn-runner";
          socket = "${workDir}/runner";
          workerId = { };
          inherit (cfg.worker)
            concurrency
            memoryMax
            nice
            platform
            ;
        }
      ]
      ++ lib.mapAttrsToList (name: runner: {
        unit = "buildbarn-runner-${name}";
        socket = "${workDir}/runner-${name}";
        workerId.runner = name;
        inherit (runner)
          concurrency
          memoryMax
          nice
          platform
          ;
      }) cfg.worker.extraRunners;

      runnerService = runner: {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = serviceConfig // {
          ExecStartPre = [
            "${getExe' pkgs.coreutils "mkdir"} -p ${workDir}/build ${workDir}/cache"
            "${getExe' pkgs.coreutils "rm"} -f ${runner.socket}"
          ];
          ExecStart = "${getExe runnerEnv} ${
            mkConfig runner.unit {
              buildDirectoryPath = "${workDir}/build";
              grpcServers = [
                {
                  listenPaths = [ runner.socket ];
                  authenticationPolicy = allow;
                }
              ];
            }
          }";
          ExecStartPost = "${getExe pkgs.bash} -c 'until [ -S ${runner.socket} ]; do sleep 0.1; done'";
          MemoryMax = runner.memoryMax;
          Nice = runner.nice;
        };
      };

      workerConfig = mkConfig "worker" {
        inherit blobstore maximumMessageSizeBytes;
        browserUrl = "http://127.0.0.1:${toString ports.schedulerAdmin}";
        scheduler.address = "${cfg.worker.server}:${toString ports.schedulerWorkers}";
        buildDirectories = [
          {
            native = {
              buildDirectoryPath = "${workDir}/build";
              cacheDirectoryPath = "${workDir}/cache";
              maximumCacheFileCount = 200000;
              maximumCacheSizeBytes = gib cfg.worker.cacheSize;
              cacheReplacementPolicy = "LEAST_RECENTLY_USED";
            };
            runners = map (runner: {
              endpoint.address = "unix://${runner.socket}";
              inherit (runner) concurrency;
              platform.properties = lib.mapAttrsToList (name: value: { inherit name value; }) runner.platform;
              workerId = runner.workerId // {
                hostname = config.networking.hostName;
              };
            }) runners;
          }
        ];
        inherit (cfg.worker) inputDownloadConcurrency outputUploadConcurrency;
        directoryCache = {
          maximumCount = 100000;
          maximumSizeBytes = 256 * 1024 * 1024;
          cacheReplacementPolicy = "LEAST_RECENTLY_USED";
        };
      };
    in
    {
      systemd.services = lib.listToAttrs (
        map (runner: lib.nameValuePair runner.unit (runnerService runner)) runners
      )
      // {
        buildbarn-worker = {
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ] ++ map (runner: "${runner.unit}.service") runners;
          wants = [ "network-online.target" ];
          serviceConfig = serviceConfig // {
            ExecStart = "${bb}/bin/bb_worker ${workerConfig}";
            RestartSec = 5;
          };
        };
      };
    };
in
{
  options.services.buildbarn = {
    storagePackage = mkOption {
      type = types.package;
      default = pkgs.callPackage ../packages/bb-storage { };
      defaultText = literalExpression "pkgs.callPackage ./packages/bb-storage { }";
      description = "bb-storage package, which runs the storage and the REAPI frontend.";
    };

    remoteExecutionPackage = mkOption {
      type = types.package;
      default = pkgs.callPackage ../packages/bb-remote-execution { };
      defaultText = literalExpression "pkgs.callPackage ./packages/bb-remote-execution { }";
      description = "bb-remote-execution package, which provides bb_scheduler, bb_worker and bb_runner.";
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/buildbarn";
      description = "Home of the buildbarn user and the default location of the storage and the worker directories.";
    };

    containerImage = mkOption {
      type = types.str;
      default = "docker://gcr.io/androidbuild-re-dockerimage/android-build-remoteexec-image@sha256:1eb7f64b9e17102b970bd7a1af7daaebdb01c3fb777715899ef462d6c6d01a45";
      description = "container-image platform property that runners advertise by default. The default is the image AOSP's Soong puts into every reclient action (remoteexec.DefaultImage). Workers never pull it, the value only has to match what clients send.";
    };

    ports = {
      frontend = mkPort 8980 "Port of the REAPI frontend, the endpoint clients connect to.";
      storage = mkPort 8981 "Port of the storage, used by the frontend, the scheduler and every worker.";
      scheduler = mkPort 8982 "Port on 127.0.0.1 where the scheduler accepts requests from the frontend.";
      schedulerWorkers = mkPort 8983 "Port where the scheduler accepts workers.";
      schedulerAdmin = mkPort 7982 "Port on 127.0.0.1 of the scheduler web UI.";
    };

    server = {
      enable = mkEnableOption "the Buildbarn storage, scheduler and REAPI frontend";

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to open the frontend, storage and scheduler worker ports in the firewall.";
      };

      storageDir = mkOption {
        type = types.path;
        default = cfg.stateDir;
        defaultText = literalExpression "config.services.buildbarn.stateDir";
        description = "Directory holding the CAS and action cache block files.";
      };

      casSize = mkOption {
        type = types.ints.positive;
        default = 150;
        description = "Content addressable storage size in GiB.";
      };

      actionCacheSize = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Action cache size in GiB.";
      };
    };

    worker = {
      enable = mkEnableOption "a Buildbarn worker";

      server = mkOption {
        type = types.str;
        example = "buildbarn.example.com";
        description = "Host name or address of the server. The worker connects to its storage and scheduler worker ports.";
      };

      workDir = mkOption {
        type = types.path;
        default = "${cfg.stateDir}/worker";
        defaultText = literalExpression ''"''${config.services.buildbarn.stateDir}/worker"'';
        description = "Directory holding the build directories, the input file cache and the runner socket. Its parent must be writable by the buildbarn user.";
      };

      concurrency = mkOption {
        type = types.ints.positive;
        default = 8;
        description = "Number of actions executed in parallel.";
      };

      memoryMax = mkOption {
        type = types.str;
        default = "16G";
        description = "systemd MemoryMax of the runner, which executes the actions.";
      };

      nice = mkOption {
        type = types.ints.between (-20) 19;
        default = 19;
        description = "Nice value of the runner and everything it executes.";
      };

      pool = mkOption {
        type = types.str;
        default = "default";
        description = "Pool platform property of the main runner. Soong's reclient rules send default for C++, links and Rust.";
      };

      platform = mkOption {
        type = types.attrsOf types.str;
        default = {
          Pool = cfg.worker.pool;
          "container-image" = cfg.containerImage;
        };
        defaultText = literalExpression ''
          {
            Pool = config.services.buildbarn.worker.pool;
            "container-image" = config.services.buildbarn.containerImage;
          }
        '';
        description = "Platform properties of the main runner. The scheduler only hands it actions whose platform matches exactly.";
      };

      extraRunners = mkOption {
        type = types.attrsOf (types.submodule runnerModule);
        default = { };
        example = literalExpression ''
          {
            java = {
              pool = "java16";
              concurrency = 2;
              memoryMax = "12G";
            };
          }
        '';
        description = "Additional runners with their own pool, slots and memory limit, sharing the worker's build directory and cache. Each one becomes a buildbarn-runner-<name> unit.";
      };

      cacheSize = mkOption {
        type = types.ints.positive;
        default = 40;
        description = "Local input file cache size in GiB.";
      };

      inputDownloadConcurrency = mkOption {
        type = types.ints.positive;
        default = 64;
        description = "Number of input files the worker downloads from the storage at once, shared by all actions. Raise it when the server is far away, since each download waits a full round trip.";
      };

      outputUploadConcurrency = mkOption {
        type = types.ints.positive;
        default = 64;
        description = "Number of output files the worker uploads to the storage at once, shared by all actions.";
      };

      runnerPackages = mkOption {
        type = types.listOf types.package;
        default = with pkgs; [
          bash
          coreutils
          diffutils
          findutils
          fontconfig
          freetype
          gawk
          gnugrep
          gnused
          libxcrypt-legacy
          ncurses5
          python3
          unzip
          which
          zip
          zlib
        ];
        defaultText = literalExpression "with pkgs; [ bash coreutils diffutils findutils fontconfig freetype gawk gnugrep gnused libxcrypt-legacy ncurses5 python3 unzip which zip zlib ]";
        description = "Packages of the FHS environment the runner executes actions in. Clients such as reclient upload their toolchain as inputs, so this only needs the userland those prebuilt binaries expect.";
      };
    };
  };

  config = mkMerge [
    (mkIf (cfg.server.enable || cfg.worker.enable) {
      users.users.buildbarn = {
        isSystemUser = true;
        group = "buildbarn";
        home = cfg.stateDir;
      };
      users.groups.buildbarn = { };

      systemd.tmpfiles.rules = [ "d ${cfg.stateDir} 0750 buildbarn buildbarn -" ];
    })
    (mkIf cfg.server.enable server)
    (mkIf cfg.worker.enable worker)
  ];
}
