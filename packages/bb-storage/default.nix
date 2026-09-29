{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule {
  pname = "bb-storage";
  version = "0-unstable-2026-09-06";

  src = fetchFromGitHub {
    owner = "buildbarn";
    repo = "bb-storage";
    rev = "ae61334ea7982155ceb317e286e2a462d875477d";
    hash = "sha256-8XcIB0rhoYZx75p4Gk9ONDsKT3VAvtYJNef1wIcSn1Q=";
  };

  vendorHash = "sha256-ubyyd9bpYLA6heCk1M6QQglBVTzjdPWGMDnTl5Hz9Tc=";

  postConfigure = ''
    chmod -R u+w vendor/google.golang.org/genproto/googleapis/bytestream
    patch -p0 -d vendor/google.golang.org/genproto/googleapis/bytestream \
      < patches/org_golang_google_genproto_googleapis_bytestream/service-registrar.diff
  '';

  subPackages = [ "cmd/bb_storage" ];

  doCheck = false;

  meta = {
    description = "Buildbarn storage daemon and REAPI frontend";
    homepage = "https://github.com/buildbarn/bb-storage";
    license = lib.licenses.asl20;
    mainProgram = "bb_storage";
  };
}
