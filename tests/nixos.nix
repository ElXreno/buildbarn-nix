self: {
  name = "buildbarn";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.default ];

      virtualisation.memorySize = 2048;
      environment.systemPackages = [ pkgs.curl ];

      services.buildbarn = {
        server = {
          enable = true;
          casSize = 1;
        };
        worker = {
          enable = true;
          server = "localhost";
          concurrency = 2;
          memoryMax = "1G";
          cacheSize = 1;
        };
      };
    };

  testScript = ''
    machine.wait_for_unit("buildbarn-frontend.service")
    machine.wait_for_unit("buildbarn-worker.service")
    machine.wait_for_open_port(8980)
    machine.wait_until_succeeds(
      "curl -sf 'http://127.0.0.1:7982/workers?filter=%7b%22all%22%3a%7b%22platformQueueName%22%3a%7b%22platform%22%3a%7b%7d%7d%7d%7d'"
      " | grep -o 'hostname=&#34;machine&#34;' | wc -l | grep -qx 2"
    )
  '';
}
