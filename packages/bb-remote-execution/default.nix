{
  lib,
  buildGoModule,
  fetchFromGitHub,
  go_1_27,
}:

(buildGoModule.override { go = go_1_27; }) {
  pname = "bb-remote-execution";
  version = "0-unstable-2026-09-08";

  src = fetchFromGitHub {
    owner = "buildbarn";
    repo = "bb-remote-execution";
    rev = "77f7642b12228833c0584453c6a2ee9452717976";
    hash = "sha256-g4IkTrDw8/mqnk3+F8VCEyqD7B2pBb8u3HdEh1dt1Do=";
  };

  vendorHash = "sha256-4BUFqCADEC7rEZPLI7RN5J+JcQ56YgH07LmhVx+cVLY=";

  subPackages = [
    "cmd/bb_runner"
    "cmd/bb_scheduler"
    "cmd/bb_worker"
  ];

  doCheck = false;

  meta = {
    description = "Buildbarn scheduler, worker and runner for remote execution";
    homepage = "https://github.com/buildbarn/bb-remote-execution";
    license = lib.licenses.asl20;
  };
}
