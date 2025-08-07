import json
import base64
import yaml
import helper.v1alpha1.main as helper
import provider_gcp.compute.v1beta1 as gcpv1beta1
import provider_gcp.compute.v1beta2 as gcpv1beta2

oxr = option("params").oxr # observed composite resource
ocds = option("params")?.ocds # observed composed resources
# _dxr = option("params").dxr # desired composite resource
# dcds = option("params").dcds # desired composed resources

assert oxr.metadata?.labels is not Undefined, "At least one label must be specified"
assert "skycluster.io/managed-by" in oxr.metadata.labels, "Label 'skycluster.io/managed-by' must be specified"

ctx = option("params")?.ctx
assert ctx is not Undefined, "Context must be provided in the params"

_extraRes = ctx["apiextensions.crossplane.io/extra-resources"]
assert _extraRes is not Undefined, "Extra resources must be provided in the context"

_provCfg = _extraRes["ProviderConfig"][0]
_skySetup = _extraRes["SkySetups"][0]

_ns = _skySetup.spec.namespace or "skycluster-system"

_oxrProvRegion = oxr.spec.providerRef.region
_oxrProvZone = oxr.spec.providerRef.zones?.primary
_oxrProvPlatform = oxr.spec.providerRef.platform
_oxrAppId = oxr.spec.applicationId or Undefined

assert _oxrProvRegion and _oxrProvZone and _oxrProvPlatform, "Provider region, primary zone, platform must be specified"
assert len(oxr.spec.subnets) > 0, "At least one subnet must be specified in the XSkyCluster spec"

assert oxr.spec?.publicKey, "SSH public key must be specified in the XSkyCluster spec"

_vpcCidr = oxr.spec.vpcCidr
_vpcCidrParts = _vpcCidr.split("/")
_vpcCidrIp = _vpcCidrParts[0]
_vpcCidrOctets = _vpcCidrIp.split(".")
_vpcCidrFirst = _vpcCidrOctets[0]
_vpcCidrSecond = _vpcCidrOctets[1]
_vpcCidrThird = _vpcCidrOctets[2]
_vpcCidrMask = _vpcCidrParts[1]



_items = []
_items += [gcpv1beta1.Network{
  metadata = {
    labels = {
      **oxr.metadata?.labels,
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("vpc"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  }
  spec = {
    forProvider = {
      autoCreateSubnetworks = False,
      # mtu = 1460
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]


_subnets = []
_subnets +=  [{
    "type" = sub.type,
    "zone" = sub.zone,
    "cidrBlock" = sub.cidr,
} for i, sub in oxr.spec.subnets]


_items += [gcpv1beta1.Subnetwork{
  metadata = {
    labels = {
      **oxr.metadata?.labels,
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("subnet{}{}".format("Private" if s.type == "private" else "Public", i)),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  }
  spec = {
    forProvider = {
      region = _oxrProvRegion,
      ipCidrRange = s.cidrBlock,
      networkSelector.matchControllerRef = True,
      privateIpGoogleAccess = True,
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
} for i, s in _subnets]

_items += [gcpv1beta1.Address{
  metadata = {
    labels = {
      **oxr.metadata?.labels,
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("privateAddress"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  }
  spec = {
    forProvider = {
      region = _oxrProvRegion,
      addressType = "INTERNAL",
      subnetworkSelector.matchControllerRef = True,
      # prefixLength = int(_vpcCidrMask),
      # purpose = "VPC_PEERING",
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]

_items += [gcpv1beta1.Address{
  metadata = {
    labels = {
      **oxr.metadata?.labels,
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("publicAddress"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  }
  spec = {
    forProvider = {
      region = _oxrProvRegion,
      addressType = "EXTERNAL",
      # subnetworkSelector.matchControllerRef = True,
      # prefixLength = int(_vpcCidrMask),
      # purpose = "VPC_PEERING",
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]

_privateAddress = ocds?["privateAddress"]?.Resource?.status?.atProvider?.address
_publicAddress = ocds?["publicAddress"]?.Resource?.status?.atProvider?.address

_items += [gcpv1beta1.Route{
  metadata = {
    labels = {
      **oxr.metadata?.labels,
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("agentRoute"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  }
  spec = {
    forProvider = {
      nextHopIp = _privateAddress
      networkSelector.matchControllerRef = True,
      destRange = "0.0.0.0/0",
      tags = ["skycluster-agent"],
    }
    providerConfigRef = {
      name = _provCfg.metadata.name,
    }
  }
}] if ocds?["privateAddress"] or ocds?["agentRoute"] else []


_tcpPorts = oxr.spec.tcpPorts
_udpPorts = oxr.spec.udpPorts

_tcpPortDefaults = [
  {"fromPort" = 30000, "toPort" = 30020},
  {"fromPort" = 51820, "toPort" = 51821},
]
_tcpPortDefaults = _tcpPortDefaults + [
  {"fromPort" = port, "toPort" = port} 
    for port in [22 80 443 6443 8080 9100 179 4789 5473 2379 10250]
]
_tcpPortsToUse = _tcpPorts if _tcpPorts else _tcpPortDefaults
_openPorts = [{
  protocol = "tcp"
  ports = _tcpPortsToUse
}]

_udpPortDefaults = [
  {"fromPort" = port, "toPort" = port} 
    for port in [3478 4500 4789 4800 8472 41641 51820 51821]
]
_udpPortsToUse = _udpPorts if _udpPorts else _udpPortDefaults
_openPorts += [{
  protocol = "udp"
  ports = _udpPortsToUse
}]

_items += [gcpv1beta1.Firewall{
  metadata = {
    labels = {
      **oxr.metadata?.labels,
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("firewall"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  }
  spec = {
    forProvider = {
      allow = [
        *[{
          protocol = p.protocol
          ports = [str(ss) for pp in p.ports for ss in range(int(pp.fromPort), int(pp.toPort) + 1)],
        } for p in _openPorts], 
        {"protocol" = "icmp"},
      ]
      networkSelector.matchControllerRef = True,
      sourceRanges = ["0.0.0.0/0"],
      direction = "INGRESS",
    }
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]


_ami = oxr.spec.gateway?.image 
assert _ami, "Gateway image must be specified in the XSkyCluster spec"

_it = oxr.spec.gateway?.flavor
assert _it, "Gateway flavor must be specified in the XSkyCluster spec"


_userData = oxr.spec.gateway?.userData 
_userData = _userData.replace("__SUBNETCIDR__", _vpcCidr) if _userData else Undefined

_items += [gcpv1beta2.Instance{
  metadata = {
    labels = {
      **oxr.metadata?.labels,
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("instance"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  }
  spec = {
    forProvider = {
      zone = _oxrProvZone,
      machineType = _it or "e2-standard-4",
      canIpForward = True,
      bootDisk = {
        initializeParams = {
          image = _ami or "projects/debian-cloud/global/images/family/debian-11",
          size = oxr.spec.gateway?.volumeSize or 20,
          type = oxr.spec.gateway?.volumeType or "pd-standard",
        },
      },      
      metadataStartupScript = ""
      metadata = {
        "ssh-keys" = "ubuntu:{}".format(oxr.spec?.publicKey) 
        "user-data" = _userData
      }
      networkInterface = [{
        subnetworkSelector.matchControllerRef = True,
        networkIp = _privateAddress,
        accessConfig = [{
          natIp = _publicAddress
        }],
      }]
    }
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}] if _publicAddress and _privateAddress or ocds?["instance"] else []


_vpcId = ocds?.vpc?.Resource?.status?.atProvider?.id
_ocdsSubnets = [v.Resource for k, v in ocds if k.find("subnet") != -1 and v.Resource]

dxr = {
  **option("params").dxr,
  status.vpc = {
    id = _vpcId
    cidrBlock = _vpcCidr 
  } if _vpcId else {},
  status.subnets = [
    {
      type = "public" if v.metadata?.labels?["skycluster.io/public-subnet"] and v.metadata?.labels?["skycluster.io/public-subnet"] == "true" else "private"
      id = v.status?.atProvider?.id
      cidrBlock = v.status?.atProvider?.cidrBlock
    } for _, v in _ocdsSubnets if v
  ]
  status.gateway = {
    publicIp = _publicAddress
    privateIp = _privateAddress
  } if _publicAddress or _privateAddress else {},
}

# Collect all resources into a list for output
items = [*_items, dxr]