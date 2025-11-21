
import helper.v1alpha1.main as helper
import provider_gcp.compute.v1beta1 as gcpv1beta1
import provider_gcp.compute.v1beta2 as gcpv1beta2

oxr = option("params").oxr # observed composite resource
ocds = option("params")?.ocds # observed composed resources

ctx = option("params")?.ctx
assert ctx is not Undefined, "Context must be provided in the params"

_extraRes = ctx["apiextensions.crossplane.io/extra-resources"]
assert _extraRes is not Undefined, "Extra resources must be provided in the context"

_skySetup = _extraRes["SkySetups"][0]
assert _skySetup is not Undefined, "SkySetup must be provided in the extra resources"

_provCfg = _extraRes["ProviderConfigs"]?[0]
assert _provCfg is not Undefined, "ProviderConfig must be provided in the extra resources"


_oxrName = oxr.metadata.name
_oxrProvRegion = oxr.spec.providerRef.region
_oxrProvZone = oxr.spec.providerRef.zone
_oxrProvPlatform = oxr.spec.providerRef.platform
_oxrAppId = oxr.spec.providerRef.applicationId or Undefined

assert _oxrProvRegion and _oxrProvZone and _oxrProvPlatform, \
  "Provider region, primary zone, platform must be specified"

_defaults = {
  deletionPolicy = "Delete"
  providerConfigRef.name = _provCfg.metadata.name
}

_openPorts = [
  {"fromPort" = r.fromPort, "toPort" = r.toPort, "protocol" = r.protocol} 
    for r in oxr.spec.securityGroups?.tcpPorts
] if oxr.spec.securityGroups?.tcpPorts else []
_openPorts += [
  {"fromPort" = r.fromPort, "toPort" = r.toPort, "protocol" = r.protocol} 
    for r in oxr.spec.securityGroups?.udpPorts
] if oxr.spec.securityGroups?.udpPorts else []

_items = []

_instanceAddresses = []
_instanceAddresses += [
  "{}/32".format(_privateAddress),
] if _privateAddress else []
_instanceAddresses += [
  "{}/32".format(_publicAddress),
] if _publicAddress else []


_items += [gcpv1beta1.Address{
  metadata = {
    labels = {
      **oxr.metadata?.labels,
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      "skycluster.io/composite-name" = _oxrName,
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("publicAddress"),
    }
  },
  spec = {
    forProvider = {
      region = _oxrProvRegion
      addressType = "EXTERNAL"
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}] if oxr.spec.publicIp or ocds?["publicAddress"] else []

_items += [gcpv1beta1.Address{
  metadata = {
    labels = {
      **oxr.metadata?.labels,
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      "skycluster.io/composite-name" = _oxrName,
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("privateAddress"),
    }
  },
  spec = {
    forProvider = {
      region = _oxrProvRegion
      addressType = "INTERNAL"
      subnetworkSelector.matchLabels = {
        **helper._filter_labels(oxr.metadata.labels, ["provider-platform", "provider-region", "application-id"])
        "skycluster.io/default-subnet" = "true"
      }
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}] 


_items += [gcpv1beta2.Firewall{
  metadata = {
    labels = {
      **oxr.metadata?.labels
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      "skycluster.io/composite-name" = _oxrName,
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("firewall"),
    }
  },
  spec = {
    forProvider = {
      allow = [{
          protocol = p.protocol
          ports = [str(ss) for pp in p.ports for ss in range(int(pp.fromPort), int(pp.toPort) + 1)],
        } for p in _openPorts]
      direction = "INGRESS"
      networkSelector.matchLabels = {
        **helper._filter_default_labels(oxr.metadata.labels)
      }
      destinationRanges = _instanceAddresses
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
} for port in _openPorts]

_privateAddress = ocds?["privateAddress"]?.Resource?.status?.atProvider?.address 
_publicAddress = ocds?["publicAddress"]?.Resource?.status?.atProvider?.address

_items += [
  _helper_instance(_privateAddress, _publicAddress)
] if _privateAddress and oxr.spec.flavor else []


dxr = {
  **option("params").dxr,
  status = {
    if _privateAddress or _publicAddress:
      network = {
        privateIp = _privateAddress or Undefined
        publicIp = _publicAddress or Undefined
      } 
    if ocds?["instance"]?.Resource?.status?.atProvider?.scheduling?.provisioningModel == "SPOT":
      spotInstance = True
  }
}

items = [*_items, dxr]


_helper_instance = lambda pvAddr, pubAddr {
  gcpv1beta2.Instance{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/composite-name" = _oxrName,
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("instance"),
      }
    },
    spec = {
      forProvider = {
        machineType = oxr.spec.flavor
        zone = _oxrProvZone, 
        bootDisk = {
          initializeParams = {
            image = oxr?.spec?.image 
            size = float(oxr.spec?.rootVolumes?[0]?.size) or 20,
            type = oxr.spec.rootVolumes?[0]?.type or "pd-standard",
          },
        }, 
        scheduling = {
          if oxr.spec.preferSpot:
            provisioningModel = "SPOT"
            automaticRestart = False
            preemptible = True 
        },
        networkInterface = [
          {
            networkIp = pvAddr
            subnetworkSelector.matchLabels = {
              **helper._filter_labels(oxr.metadata.labels, ["provider-platform", "provider-region", "application-id"])
              "skycluster.io/default-subnet" = "true"
            }
            if pubAddr:
              accessConfig = [{
                natIp = pubAddr 
              }]
          }
        ]
        metadataStartupScript = ""
        metadata = {
          "ssh-keys" = "ubuntu:{}".format(oxr.spec?.publicKey) 
          "user-data" = oxr.spec.userData
        }
        tags = [
          "instance-{}".format(_oxrName),
          # To apply defaultrouting to the default node gateway
          if not oxr.spec.publicIp:
            "skycluster-internet" # route 0.0.0.0 to gateway
          else:
            "skycluster-internal" # only route 10.0.0.0/8 to gateway
        ]
      },
      providerConfigRef = {
        name = _provCfg.metadata.name,
      },
    }
  }
}