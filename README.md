# buildbarn-nix

[Buildbarn](https://github.com/buildbarn) packaged for Nix, plus a NixOS module
that runs a small remote execution cluster: one server (storage, scheduler and
REAPI frontend) and any number of workers.

I use it to spread AOSP builds across a few machines with reclient, the client
that ships in `prebuilts/remoteexecution-client`. Other Remote Execution API
clients such as Bazel are untested.

## Usage

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    buildbarn-nix = {
      url = "github:ElXreno/buildbarn-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, buildbarn-nix, ... }:
    {
      nixosConfigurations.server = nixpkgs.lib.nixosSystem {
        modules = [
          buildbarn-nix.nixosModules.default
          {
            services.buildbarn.server = {
              enable = true;
              openFirewall = true;
            };
          }
        ];
      };

      nixosConfigurations.worker = nixpkgs.lib.nixosSystem {
        modules = [
          buildbarn-nix.nixosModules.default
          {
            services.buildbarn.worker = {
              enable = true;
              server = "server.example.com";
              concurrency = 16;
            };
          }
        ];
      };
    };
}
```

A machine can run both roles. The packages are built with your nixpkgs through
`pkgs.callPackage`, so there is no overlay to add. `overlays.default` and
`packages.<system>` are there if you want the binaries elsewhere.
`bb-remote-execution` needs `go_1_27`.

## How it fits together

- The frontend listens on `ports.frontend` (8980). Point clients there with an
  empty instance name and no TLS.
- Workers connect to the server's storage (8981) and scheduler worker port
  (8983). The server never connects to a worker, so workers can sit behind NAT.
- The scheduler web UI is on `http://127.0.0.1:7982` on the server.
- There is no authentication at all. Keep the ports on a trusted network or a
  VPN. `server.openFirewall` opens 8980, 8981 and 8983 on every interface.
- The CAS and action cache are sparse block files under `server.storageDir`,
  150 GiB and 1 GiB by default. Put them on a filesystem you don't back up.
- The runner executes actions inside an FHS environment built from
  `worker.runnerPackages`, at nice 19 and with `MemoryMax=16G` by default.
  Remote clients upload the toolchain as inputs, so the worker needs no
  compilers of its own.

## reclient

For an AOSP tree, these are the variables that point reclient at the cluster:

```sh
export USE_RBE=1 RBE_DIR=prebuilts/remoteexecution-client/live
export RBE_service=server.example.com:8980 RBE_remote_cache=server.example.com:8980 RBE_instance=
export RBE_service_no_auth=true RBE_service_no_security=true RBE_use_rpc_credentials=false
export RBE_use_unified_uploads=true RBE_use_unified_downloads=true
export RBE_CXX=1 RBE_CXX_EXEC_STRATEGY=remote_local_fallback
export NINJA_REMOTE_NUM_JOBS=64
```

Keep `NINJA_REMOTE_NUM_JOBS` well above the total number of worker slots. Under
RBE it becomes ninja's `-j`, and local-only jobs such as Java and Rust count
against it too.
