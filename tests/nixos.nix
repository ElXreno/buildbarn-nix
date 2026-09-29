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
          casCacheSize = 1;
          extraRunners.java = {
            pool = "java16";
            concurrency = 1;
            memoryMax = "512M";
          };
        };
      };
    };

  testScript =
    { nodes, ... }:
    ''
      import json
      import urllib.parse

      image = "${nodes.machine.services.buildbarn.containerImage}"

      def workers(pool):
          platform = {"properties": [{"name": "Pool", "value": pool}, {"name": "container-image", "value": image}]}
          query = urllib.parse.quote(json.dumps({"all": {"platformQueueName": {"platform": platform}}}, separators=(",", ":")))
          return f"curl -sf 'http://127.0.0.1:7982/workers?filter={query}' | grep -o 'hostname=&#34;machine&#34;' | wc -l"

      machine.wait_for_unit("buildbarn-frontend.service")
      machine.wait_for_unit("buildbarn-worker.service")
      machine.wait_for_unit("buildbarn-runner-java.service")
      machine.wait_for_open_port(8980)
      machine.wait_until_succeeds(workers("default") + " | grep -qx 2")
      machine.wait_until_succeeds(workers("java16") + " | grep -qx 1")

      machine.succeed("test -f /var/lib/buildbarn/worker/cas/blocks")
      machine.succeed("test -f /var/lib/buildbarn/worker/cas/key_location_map")
      machine.succeed("test -d /var/lib/buildbarn/worker/cas/persistent_state")
      machine.succeed("systemctl restart buildbarn-worker.service")
      machine.wait_until_succeeds(workers("default") + " | grep -qx 2")

      import time
      start = time.monotonic()
      machine.succeed("systemctl stop buildbarn-worker.service buildbarn-scheduler.service buildbarn-storage.service")
      elapsed = time.monotonic() - start
      assert elapsed < 30, f"stopping the worker together with the server took {elapsed:.0f}s"
    '';
}
