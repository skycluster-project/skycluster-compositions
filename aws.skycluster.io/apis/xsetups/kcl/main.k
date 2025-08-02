import json
import base64
import yaml
import helper.v1alpha1.main as helper
import provider_aws.ec2.v1beta1 as ec2v1beta1

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

_vpcCidr = oxr.spec.vpcCidr
_vpcCidrParts = _vpcCidr.split("/")
_vpcCidrIp = _vpcCidrParts[0]
_vpcCidrOctets = _vpcCidrIp.split(".")
_vpcCidrFirst = _vpcCidrOctets[0]
_vpcCidrSecond = _vpcCidrOctets[1]
_vpcCidrThird = _vpcCidrOctets[2]
_vpcCidrMask = _vpcCidrParts[1]

_tcpPorts = oxr.spec.tcpPorts
_udpPorts = oxr.spec.udpPorts

_items = []
_items += [ec2v1beta1.VPC{
  metadata = {
    labels = {
      **oxr.metadata?.labels,
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("vpc"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  }
  spec ={
    forProvider ={
      cidrBlock = "{0}.{1}.0.0/{2}".format(_vpcCidrFirst, _vpcCidrSecond, "16"),
      region = _oxrProvRegion,
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

_items += [ec2v1beta1.Subnet{
  metadata = {
    labels = {
      **oxr.metadata?.labels,
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, "", _oxrAppId),
      "skycluster.io/public-subnet" = "false" if s.type == "private" else "true",
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("subnet{}{}".format("Private" if s.type == "private" else "Public", i)),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  },
  spec = {
    forProvider = {
      cidrBlock = s.cidrBlock,
      region = _oxrProvRegion,
      availabilityZone = s.zone,
      vpcIdSelector.matchControllerRef = True
      mapPublicIpOnLaunch = True if s.type == "public" else False,
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
} for i, s in _subnets]

_items += [ec2v1beta1.NetworkInterface{
  metadata = {
    labels = {
      **oxr.metadata?.labels
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      "skycluster.io/interface-id" = "network-interface",
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("networkInterface"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  },
  spec = {
    forProvider = {
      sourceDestCheck = False,
      region = _oxrProvRegion,
      subnetIdSelector = {
        matchLabels = {
          **helper._filter_labels(oxr.metadata.labels, ["provider-platform", "provider-region", "application-id"])
          "skycluster.io/public-subnet" = "true",
        },
      },
      securityGroupSelector.matchControllerRef = True,
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]

_items += [ec2v1beta1.InternetGateway{
  metadata = {
    labels = {
      **oxr.metadata?.labels
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId) 
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("internet-gateway"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  },
  spec = {
    forProvider = {
      region = _oxrProvRegion,
      vpcIdSelector.matchControllerRef = True
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]

_items += [ec2v1beta1.RouteTable{
  metadata = {
    labels = {
      **oxr.metadata?.labels
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      "skycluster.io/public-route-table" = "true",
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("public-route-table"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  },
  spec = {
    forProvider = {
      region = _oxrProvRegion,
      vpcIdSelector.matchControllerRef = True
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]

_items += [ec2v1beta1.RouteTableAssociation{
  metadata = {
    labels = {
      **oxr.metadata?.labels
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      "skycluster.io/public-subnet" = "true",
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("public-route-table-association"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  },
  spec = {
    forProvider = {
      region = _oxrProvRegion,
      routeTableIdSelector = {
        matchLabels = {
          **helper._filter_default_labels(oxr.metadata.labels)
          "skycluster.io/public-route-table" = "true",
        },
      },
      subnetIdSelector = {
        matchLabels = {
          **helper._filter_labels(oxr.metadata.labels, ["provider-platform", "provider-region", "application-id"])
          "skycluster.io/public-subnet" = "true",
        },
      },
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]

_items += [ec2v1beta1.Route{
  metadata = {
    labels = {
      **oxr.metadata?.labels
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      "skycluster.io/public-route-table" = "true",
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("public-route"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  },
  spec = {
    forProvider = {
      destinationCidrBlock = "0.0.0.0/0",
      region = _oxrProvRegion,
      routeTableIdSelector = {
        matchLabels = {
          **helper._filter_default_labels(oxr.metadata.labels)
          "skycluster.io/public-route-table" = "true",
        },
      },
      gatewayIdSelector.matchControllerRef = True,
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]

# Private route table configuration
_items += [ec2v1beta1.RouteTable{
  metadata = {
    labels = {
      **oxr.metadata?.labels
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId) 
      "skycluster.io/public-route-table" = "false",
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("private-route-table"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  },
  spec = {
    forProvider = {
      region = _oxrProvRegion,
      vpcIdSelector.matchControllerRef = True
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]

_items += [ec2v1beta1.RouteTableAssociation{
  metadata = {
    labels = {
      **oxr.metadata?.labels
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("private-route-table-association"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  },
  spec = {
    forProvider = {
      region = _oxrProvRegion,
      routeTableIdSelector = {
        matchLabels = {
          **helper._filter_default_labels(oxr.metadata.labels)
          "skycluster.io/public-route-table" = "false",
        },
      },
      subnetIdSelector = {
        matchLabels = {
          **helper._filter_labels(oxr.metadata.labels, ["provider-platform", "provider-region", "application-id"])
          "skycluster.io/public-subnet" = "false",
        },
      },
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]

_items += [ec2v1beta1.Route{
  metadata = {
    labels = {
      **oxr.metadata?.labels
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      "skycluster.io/public-route-table" = "false"
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("private-route"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  },
  spec = {
    forProvider = {
      destinationCidrBlock = "0.0.0.0/0",
      region = _oxrProvRegion,
      routeTableIdSelector = {
        matchLabels = {
          **helper._filter_default_labels(oxr.metadata.labels)
          "skycluster.io/public-route-table" = "false",
        },
      },
      networkInterfaceIdSelector = {
        matchLabels = {
          **helper._filter_default_labels(oxr.metadata.labels)
          "skycluster.io/interface-id" = "network-interface",
        },
      },
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]

# Security group configuration
_items += [ec2v1beta1.SecurityGroup{
  metadata = {
    labels = {
      **oxr.metadata?.labels
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      "skycluster.io/secgroup-type" = "default",
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("security-group"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  },
  spec = {
    forProvider = {
      region = _oxrProvRegion,
      vpcIdSelector.matchControllerRef = True
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]

_items += [ec2v1beta1.SecurityGroupRule{
  metadata = {
    labels = {
      **oxr.metadata?.labels
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("security-group-rule-outbound"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  },
  spec = {
    forProvider = {
      region = _oxrProvRegion,
      securityGroupIdSelector = {
        matchLabels = helper._filter_default_labels(oxr.metadata.labels) | {
          "skycluster.io/secgroup-type" = "default",
        },
      },
      protocol = "-1",
      fromPort = 0,
      toPort = 0,
      type = "egress",
      cidrBlocks = ["0.0.0.0/0"],
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]

_items += [ec2v1beta1.SecurityGroupRule{
  metadata = {
    labels = {
      **oxr.metadata?.labels
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("security-group-rule-inbound-icmp"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  },
  spec = {
    forProvider = {
      region = _oxrProvRegion,
      securityGroupIdSelector = {
        matchLabels = helper._filter_default_labels(oxr.metadata.labels) | {
          "skycluster.io/secgroup-type" = "default",
        },
      },
      protocol = "icmp",
      fromPort = -1,
      toPort = -1,
      type = "ingress",
      cidrBlocks = ["0.0.0.0/0"],
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}]


_tcpPortDefaults = [
  {"fromPort" = 30000, "toPort" = 30020},
  {"fromPort" = 51820, "toPort" = 51821},
]
_tcpPortDefaults = _tcpPortDefaults + [
  {"fromPort" = port, "toPort" = port} 
    for port in [22 80 443 6443 8080 9100 179 4789 5473 2379 10250]
]
_tcpPortsToUse = _tcpPorts if _tcpPorts else _tcpPortDefaults

secGrpRulesInboundTcp = [
  ec2v1beta1.SecurityGroupRule{
    metadata = {
      labels = {
        **oxr.metadata?.labels
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("security-group-rule-inbound-tcp-{0}-{1}".format(port.fromPort, port.toPort)),
        **helper._is_paused_label(oxr.metadata.labels),
      }
    },
    spec = {
      forProvider = {
        region = _oxrProvRegion,
        securityGroupIdSelector = {
          matchLabels = helper._filter_default_labels(oxr.metadata.labels) | {
            "skycluster.io/secgroup-type" = "default",
          },
        },
        protocol = "tcp",
        fromPort = port.fromPort,
        toPort = port.toPort,
        type = "ingress",
        cidrBlocks = [ "0.0.0.0/0" ],
      },
      providerConfigRef = {
        name = _provCfg.metadata.name,
      },
    }
  } for port in _tcpPortsToUse
]
_items += secGrpRulesInboundTcp

_udpPortDefaults = [
  {"fromPort" = port, "toPort" = port} 
    for port in [3478 4500 4789 4800 8472 41641 51820 51821]
]
_udpPortsToUse = _udpPorts if _udpPorts else _udpPortDefaults

secGrpRulesInboundUdp = [
  ec2v1beta1.SecurityGroupRule{
    metadata = {
      labels = {
        **oxr.metadata?.labels
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId) 
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("security-group-rule-inbound-udp-{0}-{1}".format(port.fromPort, port.toPort)),
        **helper._is_paused_label(oxr.metadata.labels),
      }
    },
    spec = {
      forProvider = {
        region = _oxrProvRegion,
        securityGroupIdSelector = {
          matchLabels = helper._filter_default_labels(oxr.metadata.labels) | {
            "skycluster.io/secgroup-type" = "default",
          },
        },
        protocol = "udp",
        fromPort = port.fromPort,
        toPort = port.toPort,
        type = "ingress",
        cidrBlocks = [ "0.0.0.0/0" ],
      },
      providerConfigRef = {
        name = _provCfg.metadata.name,
      },
    }
  } for port in _udpPortsToUse
]
_items += secGrpRulesInboundUdp

# KeyPair configuration
_items += [ec2v1beta1.KeyPair{
  metadata = {
    labels = {
      **oxr.metadata?.labels 
      **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId) 
    }
    annotations = {
      **oxr.metadata?.annotations,
      **helper._set_resource_name("keypair"),
      **helper._is_paused_label(oxr.metadata.labels),
    }
  },
  spec = {
    forProvider = {
      region = _oxrProvRegion,
      publicKey = oxr.spec?.publicKey,
    },
    providerConfigRef = {
      name = _provCfg.metadata.name,
    },
  }
}] if oxr.spec?.publicKey else []

# Elastic IP configuration
_items += [
  ec2v1beta1.EIP {
    metadata = {
      labels = {
        **oxr.metadata?.labels
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("elasticIP"),
        **helper._is_paused_label(oxr.metadata.labels),
      }
    },
    spec = {
      forProvider = {
        domain = "vpc"
        networkBorderGroup = ""
        networkInterfaceSelector = {
          matchControllerRef = True
          matchLabels = {
            **helper._filter_default_labels(oxr.metadata.labels)
            "skycluster.io/interface-id" = "network-interface",
          }
        }
        region = _oxrProvRegion,
      },
      providerConfigRef = {
        name = _provCfg.metadata.name,
      },
    }
  }
]

_ami = oxr.spec.gateway?.image 
assert _ami, "Gateway image must be specified in the XSkyCluster spec"

_it = oxr.spec.gateway?.flavor
assert _it, "Gateway flavor must be specified in the XSkyCluster spec"

_keyPairId = ocds?.keypair?.Resource?.status?.atProvider?.keyPairId 
_keypairName = ocds?.keypair?.Resource?.status?.atProvider?.id 

_userData = oxr.spec.gateway?.userData 
_userData = _userData.replace("__SUBNETCIDR__", _vpcCidr) if _userData else Undefined

_items += [
  ec2v1beta1.Instance{
    metadata = {
      labels = {
        **oxr.metadata?.labels
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("gwInstance"),
        **helper._is_paused_label(oxr.metadata.labels),
      }
    },
    spec = {
      forProvider = {
        ami = _ami,
        instanceType = _it,
        sourceDestCheck = False,
        region = _oxrProvRegion,
        keyName = _keypairName,
        rootBlockDevice = [{
          volumeSize = oxr.spec?.gateway?.volumeSize or 20,
          volumeType = oxr.spec?.gateway?.volumeType or "gp2",
        }]
        networkInterface = [
          {
            networkInterfaceIdSelector = {
              matchControllerRef = True,
              matchLabels = {
                **helper._filter_default_labels(oxr.metadata.labels)
                "skycluster.io/interface-id" = "network-interface",
              }
            }
            deviceIndex = 0,
            deleteOnTermination = False
          }
        ]
        userData = _userData
      },
      providerConfigRef = {
        name = _provCfg.metadata.name,
      },
    }
  }
] if helper._ready(ocds?["networkInterface"]) or ocds?["gwInstance"] else []

_keyPairId = ocds?.keypair?.Resource?.status?.atProvider?.keyPairId 
_keypairName = ocds?.keypair?.Resource?.status?.atProvider?.id 
_vpcId = ocds?.vpc?.Resource?.status?.atProvider?.id
_ocdsSubnets = [v.Resource for k, v in ocds if k.find("subnet") != -1 and v.Resource]

dxr = {
  **option("params").dxr,
  status.keypair = {
    name = _keyPairId
    id = _keypairName
  } if _keyPairId and _keypairName else {},
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
}

# Collect all resources into a list for output
items = [*_items, dxr]