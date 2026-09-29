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
          platformKeyExtractor.static.properties = [ ];
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
      runnerSocket = "${workDir}/runner";
      blobstore = blobstoreFor "${cfg.worker.server}:${toString ports.storage}";

      runnerEnv = pkgs.buildFHSEnv {
        name = "buildbarn-runner-env";
        targetPkgs = _: cfg.worker.runnerPackages;
        runScript = "${bb}/bin/bb_runner";
      };

      runnerConfig = mkConfig "runner" {
        buildDirectoryPath = "${workDir}/build";
        grpcServers = [
          {
            listenPaths = [ runnerSocket ];
            authenticationPolicy = allow;
          }
        ];
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
            runners = [
              {
                endpoint.address = "unix://${runnerSocket}";
                inherit (cfg.worker) concurrency;
                platform = { };
                workerId.hostname = config.networking.hostName;
              }
            ];
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
      systemd.services = {
        buildbarn-runner = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = serviceConfig // {
            ExecStartPre = [
              "${getExe' pkgs.coreutils "mkdir"} -p ${workDir}/build ${workDir}/cache"
              "${getExe' pkgs.coreutils "rm"} -f ${runnerSocket}"
            ];
            ExecStart = "${getExe runnerEnv} ${runnerConfig}";
            ExecStartPost = "${getExe pkgs.bash} -c 'until [ -S ${runnerSocket} ]; do sleep 0.1; done'";
            MemoryMax = cfg.worker.memoryMax;
            Nice = cfg.worker.nice;
          };
        };
        buildbarn-worker = {
          wantedBy = [ "multi-user.target" ];
          after = [
            "network-online.target"
            "buildbarn-runner.service"
          ];
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
