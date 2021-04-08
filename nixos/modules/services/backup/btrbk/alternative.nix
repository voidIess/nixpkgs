{ config, pkgs, lib, ... }:
let
  cfg = config.services.btrbk;
  sshEnabled = cfg.sshAccess != [];
  serviceEnabled = cfg.instances != {};
  attr2Lines = attr: let
    pairs = lib.attrsets.mapAttrsToList (name: value: { inherit name value; }) attr;
    isSubsection = value: if builtins.isAttrs value then true else if builtins.isString value then false else
      throw "invalid type in btrbk config ${builtins.typeOf value}";
    sortedPairs = lib.lists.partition (x: isSubsection x.value) pairs;
  in
    lib.flatten (
      # non subsections go first
      (
        map (pair: [ "${pair.name} ${pair.value}" ]) sortedPairs.wrong
      )
      ++ # subsections go last
      (
        map (
          pair:
            lib.mapAttrsToList (
              childname: value:
                [ "${pair.name} ${childname}" ] ++ (map (x: " " + x) (attr2Lines value))
            ) pair.value
        ) sortedPairs.right
      )
    )
  ;
  addDefaults = settings: { backend = "btrfs-progs-sudo"; } // settings;
  mkConfigFile = settings: lib.concatStringsSep "\n" (attr2Lines (addDefaults settings));
  configTest = name: settings: let
    configFile = pkgs.writeText "btrbk-${name}.conf" (mkConfigFile settings);
  in
    pkgs.runCommand "btrbk-${name}-config-test" {} ''
      mkdir foo
      if (set +o pipefail; ${pkgs.btrbk}/bin/btrbk -c ${configFile} ls foo 2>&1 | grep ${configFile});
      then
      echo btrbk configuration is invalid
      cat ${configFile}
      exit 1
      fi;
      touch $out
    '';

    btrbkOptions = import ./btrbk-options.nix {inherit config lib pkgs;};

    # Different Sections in the config accept different options.
    # Theese sets inherit the respective valid options.
    # The names used here, are the same names as in $(man btrbk.conf)
    optionSections = {
      global = {
        inherit (btrbkOptions)
        snapshotDir extraOptions timestampFormat snapshotCreate incremental
        noauto preserveDayOfWeek sshUser sshIdentity sshCompression sshCipherSpec
        preserveHourOfDay snapshotPreserve snapshotPreserveMin targetPreserve
        targetPreserveMin stream_compress stream_compress_level;
      };

      subvolume = {
        inherit (btrbkOptions)
        snapshotDir extraOptions timestampFormat snapshotName snapshotCreate
        incremental noauto preserveDayOfWeek sshUser sshIdentity sshCompression
        sshCipherSpec preserveHourOfDay snapshotPreserve snapshotPreserveMin
        targetPreserve targetPreserveMin stream_compress stream_compress_level;
      };

      target = {
        inherit (btrbkOptions)
        extraOptions incremental noauto preserveDayOfWeek sshUser sshIdentity
        sshCompression sshCipherSpec preserveHourOfDay targetPreserve
        targetPreserveMin stream_compress stream_compress_level;
      };

      volume = {
        inherit (btrbkOptions)
        snapshotDir extraOptions timestampFormat snapshotCreate incremental
        noauto preserveDayOfWeek sshUser sshIdentity sshCompression sshCipherSpec
        preserveHourOfDay snapshotPreserve snapshotPreserveMin targetPreserve
        targetPreserveMin stream_compress stream_compress_level;
      };
    };

    # Each btrfs volume is configured as an option of type submodule
    # The following set specifies this submodule
    #
    # For example
    # services.btrbk."/home/user".subvolumes."Movies".snapshotDir = "/snapshots";
    # will generate the following excerpt in the final config:
    #
    # volume /home/user
    #   subvolume Movies
    #     snapshot_dir = "/snapshots";
    volumeSubmodule =
      ({name, config, ... }:
      {
        options = {
          subvolumes = lib.mkOption {
              type = subsectionDataType optionSections.subvolume;
              default = [];
              example = [ "/home/user/important_data" "/mount/even_more_important_data"];
              description = "A list of subvolumes which should be backed up.";
          };
          targets = lib.mkOption {
            type = subsectionDataType optionSections.target;
            default = [];
            example = ''[ "/mount/backup_drive" ]'';
            description = "A list of targets where backups of this volume should be stored.";
          };
        } // optionSections.volume;
    });

    # A subsection is either typed as a list of strings
    # or in more advanced cases as a list of options which specificly and only
    # applys to this subsection
    #
    # if the later is the case, the bound variable 'options' will be elliminated
    # in favor of the kind of options which can be used with this type of subsection
    subsectionDataType = options: with lib.types; either (listOf str) (attrsOf (submodule
      ({name, config, ...}:
      {
        inherit options;
      }))
    );
in
{
  options = {
    services.btrbk = {
      extraPackages = lib.mkOption {
        description = "Extra packages for btrbk, like compression utilities for <literal>stream_compress</literal>";
        type = lib.types.listOf lib.types.package;
        default = [];
        example = lib.literalExample "[ pkgs.xz ]";
      };
      niceness = lib.mkOption {
        description = "Niceness for local instances of btrbk. Also applies to remote ones connecting via ssh when positive.";
        type = lib.types.ints.between (-20) 19;
        default = 10;
      };
      ioSchedulingClass = lib.mkOption {
        description = "IO scheduling class for btrbk (see ionice(1) for a quick description). Applies to local instances, and remote ones connecting by ssh if set to idle.";
        type = lib.types.enum [ "idle" "best-effort" "realtime" ];
        default = "idle";
      };
      instances = lib.mkOption {
        description = "Set of btrbk instances. The instance named <literal>btrbk</literal> is the default one.";
        type = with lib.types;
          attrsOf (
            submodule {
              options = {
                onCalendar = lib.mkOption {
                  type = lib.types.str;
                  default = "daily"; # every 3 minutes
                  description = "How often this btrbk instance is started. See systemd.time(7) for more information about the format.";
                };
                settings =
                ({
                  volumes = lib.mkOption {
                    type = with types; attrsOf (submodule volumeSubmodule);
                    default = { };
                    description =
                    "The configuration for a specific volume.
                    The key of each entry is a string, reflecting the path of that volume.";
                    example = {
                     "/mount/btrfs_volumes" =
                      {
                        subvolumes = [ "btrfs_volume/important_files" ];
                        targets = [ "/mount/backup_drive" ];
                      };
                    };
                  };
                } // optionSections.global);
              };
            }
          );
        default = {};
      };
      sshAccess = lib.mkOption {
        type = with lib.types; listOf (
          submodule {
            options = {
              key = lib.mkOption {
                type = str;
                description = "SSH public key allowed to login as user <literal>btrbk</literal> to run remote backups.";
              };
              roles = lib.mkOption {
                type = listOf (enum [ "info" "source" "target" "delete" "snapshot" "send" "receive" ]);
                example = [ "source" "info" "send" ];
                description = "What actions can be performed with this SSH key. See ssh_filter_btrbk(1) for details";
              };
            };
          }
        );
        default = [];
      };
    };

  };

  ####### implementation
  config = lib.mkIf (sshEnabled || serviceEnabled) {
    environment.systemPackages = [ pkgs.btrbk ] ++ cfg.extraPackages;
    security.sudo.extraRules = [
      {
        users = [ "btrbk" ];
        commands = [
          { command = "${pkgs.btrfs-progs}/bin/btrfs"; options = [ "NOPASSWD" ]; }
          { command = "${pkgs.coreutils}/bin/mkdir"; options = [ "NOPASSWD" ]; }
          { command = "${pkgs.coreutils}/bin/readlink"; options = [ "NOPASSWD" ]; }
          # for ssh, they are not the same than the one hard coded in ${pkgs.btrbk}
          { command = "/run/current-system/bin/btrfs"; options = [ "NOPASSWD" ]; }
          { command = "/run/current-system/sw/bin/mkdir"; options = [ "NOPASSWD" ]; }
          { command = "/run/current-system/sw/bin/readlink"; options = [ "NOPASSWD" ]; }
        ];
      }
    ];
    users.users.btrbk = {
      isSystemUser = true;
      # ssh needs a home directory
      home = "/var/lib/btrbk";
      createHome = true;
      shell = "${pkgs.bash}/bin/bash";
      group = "btrbk";
      openssh.authorizedKeys.keys = map (
        v:
          let
            options = lib.concatMapStringsSep " " (x: "--" + x) v.roles;
            ioniceClass = {
              "idle" = 3;
              "best-effort" = 2;
              "realtime" = 1;
            }.${cfg.ioSchedulingClass};
          in
            ''command="${pkgs.utillinux}/bin/ionice -t -c ${toString ioniceClass} ${lib.optionalString (cfg.niceness >= 1) "${pkgs.coreutils}/bin/nice -n ${toString cfg.niceness}"} ${pkgs.btrbk}/share/btrbk/scripts/ssh_filter_btrbk.sh --sudo ${options}" ${v.key}''
      ) cfg.sshAccess;
    };
    users.groups.btrbk = {};
    systemd.tmpfiles.rules = [
      "d /var/lib/btrbk 0750 btrbk btrbk"
      "d /var/lib/btrbk/.ssh 0700 btrbk btrbk"
      "f /var/lib/btrbk/.ssh/config 0700 btrbk btrbk - StrictHostKeyChecking=accept-new"
    ];
    system.extraDependencies = lib.mapAttrsToList (name: instance: configTest name instance.settings) cfg.instances;
    environment.etc = lib.mapAttrs' (
      name: instance: {
        name = "btrbk/${name}.conf";
        value.text = "test"; # mkConfigFile instance.settings;
      }
    ) cfg.instances;
    systemd.services = lib.mapAttrs' (
      name: _: {
        name = "btrbk-${name}";
        value = {
          description = "Takes BTRFS snapshots and maintains retention policies.";
          unitConfig.Documentation = "man:btrbk(1)";
          path = [ "/run/wrappers" ] ++ cfg.extraPackages;
          serviceConfig = {
            User = "btrbk";
            Group = "btrbk";
            Type = "oneshot";
            ExecStart = "${pkgs.btrbk}/bin/btrbk -c /etc/btrbk/${name}.conf run";
            Nice = cfg.niceness;
            IOSchedulingClass = cfg.ioSchedulingClass;
            StateDirectory = "btrbk";
          };
        };
      }
    ) cfg.instances;

    systemd.timers = lib.mapAttrs' (
      name: instance: {
        name = "btrbk-${name}";
        value = {
          description = "Timer to take BTRFS snapshots and maintain retention policies.";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = instance.onCalendar;
            AccuracySec = "10min";
            Persistent = true;
          };
        };
      }
    ) cfg.instances;
  };

}
