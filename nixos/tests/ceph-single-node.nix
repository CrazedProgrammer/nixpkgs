import ./make-test.nix ({pkgs, lib, ...}:

let
  cfg = {
    clusterId = "066ae264-2a5d-4729-8001-6ad265f50b03";
    monA = {
      name = "a";
      ip = "192.168.1.1";
    };
    osd0 = {
      name = "0";
      key = "AQBCEJNa3s8nHRAANvdsr93KqzBznuIWm2gOGg==";
      uuid = "55ba2294-3e24-478f-bee0-9dca4c231dd9";
    };
    osd1 = {
      name = "1";
      key = "AQBEEJNac00kExAAXEgy943BGyOpVH1LLlHafQ==";
      uuid = "5e97a838-85b6-43b0-8950-cb56d554d1e5";
    };
  };
  generateCephConfig = { daemonConfig }: {
    enable = true;
    global = {
      fsid = cfg.clusterId;
      monHost = cfg.monA.ip;
      monInitialMembers = cfg.monA.name;
    };
  } // daemonConfig;

  generateHost = { pkgs, cephConfig, networkConfig, ... }: {
    virtualisation = {
      memorySize = 512;
      emptyDiskImages = [ 20480 20480 ];
      vlans = [ 1 ];
    };

    networking = networkConfig;

    environment.systemPackages = with pkgs; [
      bash
      sudo
      ceph
      xfsprogs
    ];

    boot.kernelModules = [ "xfs" ];

    services.ceph = cephConfig;
  };

  networkMonA = {
    dhcpcd.enable = false;
    interfaces.eth1.ipv4.addresses = pkgs.lib.mkOverride 0 [
      { address = cfg.monA.ip; prefixLength = 24; }
    ];
  };
  cephConfigMonA = generateCephConfig { daemonConfig = {
    mon = {
      enable = true;
      daemons = [ cfg.monA.name ];
    };
    mgr = {
      enable = true;
      daemons = [ cfg.monA.name ];
    };
    osd = {
      enable = true;
      daemons = [ cfg.osd0.name cfg.osd1.name ];
    };
  }; };

  # Following deployment is based on the manual deployment described here:
  # https://docs.ceph.com/docs/master/install/manual-deployment/
  # For other ways to deploy a ceph cluster, look at the documentation at
  # https://docs.ceph.com/docs/master/
  testscript = { ... }: ''
    startAll;

    $monA->waitForUnit("network.target");

    # Bootstrap ceph-mon daemon
    $monA->mustSucceed(
      "sudo -u ceph ceph-authtool --create-keyring /tmp/ceph.mon.keyring --gen-key -n mon. --cap mon 'allow *'",
      "sudo -u ceph ceph-authtool --create-keyring /etc/ceph/ceph.client.admin.keyring --gen-key -n client.admin --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *' --cap mgr 'allow *'",
      "sudo -u ceph ceph-authtool /tmp/ceph.mon.keyring --import-keyring /etc/ceph/ceph.client.admin.keyring",
      "monmaptool --create --add ${cfg.monA.name} ${cfg.monA.ip} --fsid ${cfg.clusterId} /tmp/monmap",
      "sudo -u ceph ceph-mon --mkfs -i ${cfg.monA.name} --monmap /tmp/monmap --keyring /tmp/ceph.mon.keyring",
      "sudo -u ceph touch /var/lib/ceph/mon/ceph-${cfg.monA.name}/done",
      "systemctl start ceph-mon-${cfg.monA.name}"
    );
    $monA->waitForUnit("ceph-mon-${cfg.monA.name}");
    $monA->mustSucceed("ceph mon enable-msgr2");

    # Can't check ceph status until a mon is up
    $monA->succeed("ceph -s | grep 'mon: 1 daemons'");

    # Start the ceph-mgr daemon, after copying in the keyring
    $monA->mustSucceed(
      "sudo -u ceph mkdir -p /var/lib/ceph/mgr/ceph-${cfg.monA.name}/",
      "ceph auth get-or-create mgr.${cfg.monA.name} mon 'allow profile mgr' osd 'allow *' mds 'allow *' > /var/lib/ceph/mgr/ceph-${cfg.monA.name}/keyring",
      "systemctl start ceph-mgr-${cfg.monA.name}"
    );
    $monA->waitForUnit("ceph-mgr-a");
    $monA->waitUntilSucceeds("ceph -s | grep 'quorum ${cfg.monA.name}'");
    $monA->waitUntilSucceeds("ceph -s | grep 'mgr: ${cfg.monA.name}(active,'");

    # Bootstrap both OSDs
    $monA->mustSucceed(
      "mkfs.xfs /dev/vdb",
      "mkfs.xfs /dev/vdc",
      "mkdir -p /var/lib/ceph/osd/ceph-${cfg.osd0.name}",
      "mount /dev/vdb /var/lib/ceph/osd/ceph-${cfg.osd0.name}",
      "mkdir -p /var/lib/ceph/osd/ceph-${cfg.osd1.name}",
      "mount /dev/vdc /var/lib/ceph/osd/ceph-${cfg.osd1.name}",
      "ceph-authtool --create-keyring /var/lib/ceph/osd/ceph-${cfg.osd0.name}/keyring --name osd.${cfg.osd0.name} --add-key ${cfg.osd0.key}",
      "ceph-authtool --create-keyring /var/lib/ceph/osd/ceph-${cfg.osd1.name}/keyring --name osd.${cfg.osd1.name} --add-key ${cfg.osd1.key}",
      "echo '{\"cephx_secret\": \"${cfg.osd0.key}\"}' | ceph osd new ${cfg.osd0.uuid} -i -",
      "echo '{\"cephx_secret\": \"${cfg.osd1.key}\"}' | ceph osd new ${cfg.osd1.uuid} -i -"
    );

    # Initialize the OSDs with regular filestore
    $monA->mustSucceed(
      "ceph-osd -i ${cfg.osd0.name} --mkfs --osd-uuid ${cfg.osd0.uuid}",
      "ceph-osd -i ${cfg.osd1.name} --mkfs --osd-uuid ${cfg.osd1.uuid}",
      "chown -R ceph:ceph /var/lib/ceph/osd",
      "systemctl start ceph-osd-${cfg.osd0.name}",
      "systemctl start ceph-osd-${cfg.osd1.name}"
    );
    $monA->waitUntilSucceeds("ceph osd stat | grep -e '2 osds: 2 up[^,]*, 2 in'");
    $monA->waitUntilSucceeds("ceph -s | grep 'mgr: ${cfg.monA.name}(active,'");
    $monA->waitUntilSucceeds("ceph -s | grep 'HEALTH_OK'");

    $monA->mustSucceed(
      "ceph osd pool create single-node-test 100 100",
      "ceph osd pool ls | grep 'single-node-test'",
      "ceph osd pool rename single-node-test single-node-other-test",
      "ceph osd pool ls | grep 'single-node-other-test'"
    );
    $monA->waitUntilSucceeds("ceph -s | grep '1 pools, 100 pgs'");
    $monA->mustSucceed(
      "ceph osd getcrushmap -o crush",
      "crushtool -d crush -o decrushed",
      "sed 's/step chooseleaf firstn 0 type host/step chooseleaf firstn 0 type osd/' decrushed > modcrush",
      "crushtool -c modcrush -o recrushed",
      "ceph osd setcrushmap -i recrushed",
      "ceph osd pool set single-node-other-test size 2"
    );
    $monA->waitUntilSucceeds("ceph -s | grep 'HEALTH_OK'");
    $monA->waitUntilSucceeds("ceph -s | grep '100 active+clean'");
    $monA->mustFail(
      "ceph osd pool ls | grep 'multi-node-test'",
      "ceph osd pool delete single-node-other-test single-node-other-test --yes-i-really-really-mean-it"
    );

    # Shut down ceph by stopping ceph.target.
    $monA->mustSucceed("systemctl stop ceph.target");

    # Start it up
    $monA->succeed("systemctl start ceph.target");
    $monA->waitForUnit("ceph-mon-${cfg.monA.name}");
    $monA->waitForUnit("ceph-mgr-${cfg.monA.name}");
    $monA->waitForUnit("ceph-osd-${cfg.osd0.name}");
    $monA->waitForUnit("ceph-osd-${cfg.osd1.name}");

    # Ensure the cluster comes back up again
    $monA->succeed("ceph -s | grep 'mon: 1 daemons'");
    $monA->waitUntilSucceeds("ceph -s | grep 'quorum ${cfg.monA.name}'");
    $monA->waitUntilSucceeds("ceph osd stat | grep -e '2 osds: 2 up[^,]*, 2 in'");
    $monA->waitUntilSucceeds("ceph -s | grep 'mgr: ${cfg.monA.name}(active,'");
    $monA->waitUntilSucceeds("ceph -s | grep 'HEALTH_OK'");
  '';
in {
  name = "basic-single-node-ceph-cluster";
  meta = with pkgs.stdenv.lib.maintainers; {
    maintainers = [ lejonet johanot ];
  };

  nodes = {
    monA = generateHost { pkgs = pkgs; cephConfig = cephConfigMonA; networkConfig = networkMonA; };
  };

  testScript = testscript;
})
