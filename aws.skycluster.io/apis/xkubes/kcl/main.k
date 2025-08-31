import json
import yaml
import crypto
import helper.v1alpha1.main as helper
import provider_aws.eks.v1beta1 as eksv1beta1
import provider_aws.eks.v1beta2 as eksv1beta2
import provider_aws.iam.v1beta1 as iamv1beta1
import provider_aws.ec2.v1beta1 as ec2v1beta1
import provider_helm.v1beta1 as helmv1beta1
import provider_kubernetes.v1alpha1 as k8sv1alpha1

oxr = option("params")?.oxr
assert oxr.metadata?.labels is not Undefined, "At least one label must be specified"
assert "skycluster.io/managed-by" in oxr.metadata.labels, "Label 'skycluster.io/managed-by' must be specified"
ocds = option("params")?.ocds

ctx = option("params")?.ctx
assert ctx is not Undefined, "Context must be provided in the params"

_oxrProvRegion = oxr.spec.providerRef.region
_oxrProvZone = oxr.spec.providerRef.zones.primary
_oxrProvPlatform = oxr.spec.providerRef.platform
_oxrAppId = oxr.spec.providerRef.applicationId or Undefined
_oxrServiceCidr = oxr.spec.serviceCidr or Undefined

assert _oxrProvRegion and _oxrProvZone and _oxrProvPlatform, \
  "Provider region, primary zone, platform must be specified"
assert _oxrServiceCidr, "Service CIDR must be specified in the oxr spec"

_extraRes = ctx["apiextensions.crossplane.io/extra-resources"]
assert _extraRes is not Undefined, "Extra resources must be provided in the context"
_provCfg = _extraRes["ProviderConfigs"][0]
_skySetup = _extraRes["SkySetups"][0]
_xSetup = _extraRes["XSetup"][0]
_conSecret = _extraRes["ConnectionSecrets"][0]
_ns = "skycluster-system"
_connectionSecretNamespace = _ns
_nodeGroups = oxr.spec.nodeGroups
_principalArn = oxr.spec?.principalArn or Undefined

_defaults = {
  deletionPolicy = "Delete"
  providerConfigRef.name = _provCfg.metadata.name
}

_subnets = [{
  type = "public"
  cidrBlock = oxr.spec.podCidr.public
  zone = oxr.spec.providerRef.zones.primary
}, {
  type = "private"
  cidrBlock = oxr.spec.podCidr.private
  zone = oxr.spec.providerRef.zones.secondary
}]

_items = []

_items += [_helper_role("controlplaneRole")]
_items += [_helper_subnet(i, s) for i, s in _subnets]
# Route configuration
# Public route table
_items += [_helper_route_table("public")]
_items += [_helper_route_table_association("public")]
_items += [_helper_route("public")]
# Private route table
_items += [_helper_route_table("private")]
_items += [_helper_route_table_association("private")]
_items += [_helper_route("private")]

_items += [_helper_cluster("k8sCluster")]

_items += [
  _helper_cluster_auth("k8sAuth")
] if helper._ready(ocds?["k8sCluster"]) or ocds?["k8sAuth"] else []

_items += [
  # The public node group is used to create nodes acting as gateways for the cluster.
  _helper_node_group(i, ng) for i, ng in _nodeGroups
] if helper._ready(ocds?["vpc-cni-addon"]) or ocds?["nodeGroupPublic"] else []

_items += [_helper_role_node_group("nodegroupRole")]

_items += [
  _helper_access_entry(_principalArn),
  _helper_access_policy_assoc(_principalArn)
] if _principalArn else []


_items += [
  _helper_addon_cni()
] if helper._ready(ocds?["k8sAuth"]) or ocds?["vpc-cni-addon"] else []


_nodeGroupReadiness = any_true(
  [helper._ready(ocds?["nodeGroup{}{}".format("Public" if ng.publicAccess else "Private", i)] ) for i, ng in _nodeGroups]
)

_items += [
  _helper_addon_csi()
] if _nodeGroupReadiness or ocds?["aws-ebs-csi-driver-addon"] else []


_items += [
  _helper_addon_pod_identity()
] if _nodeGroupReadiness or ocds?["eks-pod-identity-agent"] else []

_providerConfigTypes = ["helm", "kubernetes"]
_items += [
  _helper_providerCfg(t) \
    for t in _providerConfigTypes \
      if helper._ready(ocds?["k8sAuth"]) or ocds?["providerConfig{}".format(t.capitalize())]
]

_items += [{
  apiVersion: "meta.krm.kcl.dev/v1alpha1"
  kind: "CompositeConnectionDetails"
  data: {
    kubeconfig = ocds?["k8sAuth"]?.ConnectionDetails?.kubeconfig
  } if ocds?["k8sAuth"] else {}
}]


_items += [
  _helper_k8s_providerCfg("eksClusterConfig")
] if helper._ready(ocds?["k8sCluster"]) or ocds?["eksClusterConfig"] else []

_items += [
  _helper_helm_providerCfg("eksClusterConfigHelm")
] if helper._ready(ocds?["k8sCluster"]) or ocds?["eksClusterConfigHelm"] else []


_nodeGroupNames = [
  "nodeGroup{}{}".format("Public" if ng.publicAccess else "Private", i) \
    for i, ng in _nodeGroups
]

_sshSecGroupIds = [
  ocds?[_n]?.Resource?.status?.atProvider?.resources?[0]?.remoteAccessSecurityGroupId \
    for _n in _nodeGroupNames
]

_udpPortDefaults = [{"fromPort" = port, "toPort" = port} for port in [4500 4800]]

#
# SecurityGroupRule
#
_items += [
  ec2v1beta1.SecurityGroup{
    metadata = {
      annotations = {
        **helper._set_resource_name("sshSecGroup{}".format(_i) ),
        "crossplane.io/external-name" = _s
      }
    },
    spec = {
      managementPolicies = ["Observe"]
      forProvider = {
        region = _oxrProvRegion
      }
      providerConfigRef = {
        name = _provCfg.metadata.name,
      },
    }
  } for _i, _s in _sshSecGroupIds
] if all_true(_sshSecGroupIds) else []

#
# SecurityGroupRule
#
_items += [
  ec2v1beta1.SecurityGroupRule{
    metadata = {
      labels = {
        **oxr.metadata?.labels
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId) 
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("secGroupRuleUdp{}-{}-{}".format(_i, port.fromPort, port.toPort)),
        **helper._is_paused_label(oxr.metadata.labels),
      }
    },
    spec = {
      forProvider = {
        region = _oxrProvRegion,
        securityGroupId = _s
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
  } for _i, _s in _sshSecGroupIds for port in _udpPortDefaults 
] if all_true(_sshSecGroupIds) else []

#
# SecurityGroupRule
#
_items += [
  ec2v1beta1.SecurityGroupRule{
    metadata = {
      labels = {
        **oxr.metadata?.labels
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("secGroupRule{}".format(_i)),
        **helper._is_paused_label(oxr.metadata.labels),
      }
    },
    spec = {
      forProvider = {
        region = _oxrProvRegion,
        securityGroupId = _s
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
  } for _i, _s in _sshSecGroupIds
] if all_true(_sshSecGroupIds) else []


_dummy_log = {
  nodeGroupNames = ",".join(_nodeGroupNames),
  sshSecGroupIds = ",".join(_sshSecGroupIds),
  sshGroupNames = ",".join(["sshSecGroup{}".format(_i) for _i, _s in _sshSecGroupIds])
}

dxr = {
  **option("params").dxr,
  status = {
    serviceCidr = oxr.spec?.serviceCidr
    podCidr = oxr.spec?.podCidr?.cidr
    # For easier access to cluster:
    # clusterSecretName = [v.secret?.observed for _, v in _ctrlObjData]?[0]
    # if _subnetId or _networkId:
      # subnet = {
      #   subnetId = _subnetId
      #   networkId = _networkId
      # }
    controllers = [{publicIp = ocds?["k8sCluster"]?.Resource?.status?.atProvider?.endpoint}]
    # agents = [
    #   {
    #     **{k = v for k ,v in obj if k in ["privateIp", "publicIp", "instanceType", "publicAccess"]} 
    #     **{k = str(v?["observed"]) for k, v in obj if k in ["ssh", "agent"]}
    #     **{
    #       k = {
    #         a = str(b?["observed"]) for a, b in v
    #       } for k, v in obj if k in ["providerConfigs"]
    #     }
    #   } for _, obj in _agentObjData
    # ]
  }
  # status.log = yaml.encode(_dummy_log),
  # status.serviceCidr = _oxrServiceCidr
  # status.podCidr = "10.10.10.10/24"
}


items =  [*_items, dxr]


#
############### Helper Mixins ###############
#

_helper_cluster = lambda s {
  eksv1beta2.Cluster {
    metadata = {
      labels = {
        **oxr.metadata?.labels
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name(s),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec: _defaults | {
      forProvider = {
        region = _oxrProvRegion
        version = "1.32"
        accessConfig = {
          authenticationMode = "API_AND_CONFIG_MAP"
          bootstrapClusterCreatorAdminPermissions = True
        }
        kubernetesNetworkConfig = {
          serviceIpv4Cidr = _oxrServiceCidr
        }
        roleArnSelector = {
          matchControllerRef = True
          matchLabels = {
            "skycluster.io/iam-role" = "controlplane"
          }
        }
        vpcConfig = {
          endpointPrivateAccess = True
          securityGroupIdSelector = {
            matchLabels = {
              **helper._filter_default_labels(oxr.metadata.labels)
              # May need to create specific security group
            }
          }
          subnetIdSelector = {
            matchLabels = {
              "skycluster.io/cluster-name" = oxr.metadata.name
            }
          }
        }
      }
    }
  }
}

_helper_providerCfg = lambda t {
  {
    apiVersion = "{}.crossplane.io/{}".format(t, "v1beta1" if t == "helm" else "v1alpha1")
    kind = "ProviderConfig"
    metadata = {
      # name = "skycluster"
      annotations = {
        **helper._set_resource_name("providerConfig{}".format(t.capitalize()))
        "krm.kcl.dev/ready" = "True"
      }
    }
    spec.credentials = {
      secretRef = {
        name = "k8s-eks-{}".format(oxr.metadata.name)
        namespace = _connectionSecretNamespace
        key = "kubeconfig"
      }
      source = "Secret"
    }
  }
}

_helper_k8s_providerCfg = lambda s {
  k8sv1alpha1.ProviderConfig {
    metadata = {
      labels = {"skycluster.io/managed-by": "skycluster"}
      annotations = {
          **oxr.metadata?.annotations,
          **helper._set_resource_name(s),
          "krm.kcl.dev/ready": "True"
      }
    }
    spec = {
      credentials = {
        source = "Secret"
        secretRef = {
          namespace = _ns
          name = "k8s-eks-{}".format(oxr.metadata.name)
          key = "kubeconfig"
        }
      }
    }
  }
}

_helper_helm_providerCfg = lambda s {
  helmv1beta1.ProviderConfig {
    metadata = {
      labels = {"skycluster.io/managed-by": "skycluster"}
      annotations = {
          **oxr.metadata?.annotations,
          **helper._set_resource_name(s),
          "krm.kcl.dev/ready": "True"
      }
    }
    spec = {
      credentials = {
        source: "Secret"
        secretRef = {
          namespace = _ns
          name = "k8s-eks-{}".format(oxr.metadata.name)
          key = "kubeconfig"
        }
      }
    }
  }
}

_helper_addon_pod_identity = lambda {
  eksv1beta1.Addon{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("eks-pod-identity-agent-addon"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec: _defaults | {
      forProvider = {
        region = _oxrProvRegion
        addonName = "eks-pod-identity-agent"
        clusterNameSelector.matchControllerRef = True
      }
    }
  }
}

_helper_addon_cni = lambda {
  eksv1beta1.Addon{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("vpc-cni-addon"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec: _defaults | {
      forProvider = {
        region = _oxrProvRegion
        addonName = "vpc-cni"
        clusterNameSelector.matchControllerRef = True
        # see https://github.com/aws/amazon-vpc-cni-k8s/blob/master/README.md for different options
        configurationValues: '{"env": {"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG":"false"}}'
      }
    }
  }
}

_helper_addon_csi = lambda {
  eksv1beta1.Addon{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("aws-ebs-csi-driver-addon"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec: _defaults | {
      forProvider = {
        region = _oxrProvRegion
        addonName = "aws-ebs-csi-driver"
        clusterNameSelector.matchControllerRef = True
        configurationValues = '{"defaultStorageClass": {"enabled": true}}'
      }
    }
  }
}

_helper_access_policy_assoc = lambda arn {
  eksv1beta1.AccessPolicyAssociation{
    # force recreate when principalArn changes
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name(crypto.sha256("apc{}".format(arn))),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec: _defaults | {
      forProvider = {
        region = _oxrProvRegion
        accessScope: {
          type: "cluster"
        }
        clusterNameSelector .matchControllerRef = True
        policyArn: "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        principalArnSelector = {
          matchControllerRef = True
        }
      }
    }
  }
}

_helper_access_entry = lambda arn {
  eksv1beta1.AccessEntry{
    # force recreate when principalArn changes
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name(crypto.sha256("accEntry{}".format(arn))),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec: _defaults | {
      forProvider = {
        region = _oxrProvRegion
        clusterNameSelector = {
          matchControllerRef = True
        }
        type = "STANDARD"
        principalArn = arn
      }
    }
  }
}

_helper_role = lambda s {
  iamv1beta1.Role {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/iam-role" = "controlplane"
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name(s),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec: _defaults | {
      forProvider = {
        forceDetachPolicies = True
        managedPolicyArns = [
          "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
        ]
        assumeRolePolicy = json.encode({
          Version = "2012-10-17",
          Statement = [
            {
              Effect = "Allow",
              Principal = {
                Service = ["eks.amazonaws.com"]
              },
              Action = ["sts:AssumeRole"]
            }
          ]
        })
      }
    }
  }
}

_helper_cluster_auth = lambda s {
  eksv1beta1.ClusterAuth{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name(s),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec: _defaults | {
      forProvider = {
        region = _oxrProvRegion
        clusterNameSelector.matchControllerRef = True
      }
      writeConnectionSecretToRef = {
        name = "k8s-eks-{}".format(oxr.metadata.name)
        namespace = _connectionSecretNamespace
      }
    }
  }
}

_helper_node_group = lambda i, ng {
  eksv1beta2.NodeGroup{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/public-subnet" = "true" if ng.publicAccess else "false"
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("nodeGroup{}{}".format("Public" if ng.publicAccess else "Private", i)),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec: _defaults | {
      initProvider = {
        scalingConfig = {
          desiredSize = ng.nodeCount or 1
        }
      }
      forProvider = {
        region = _oxrProvRegion
        clusterNameSelector.matchControllerRef = True
        nodeRoleArnSelector = {
          matchControllerRef = True
          matchLabels = {
            "skycluster.io/iam-role" = "nodegroup"
          }
        }
        scalingConfig = {
          minSize = ng.autoScaling?.minSize or 1
          maxSize = (ng.autoScaling?.maxSize if not ng.publicAccess else 1) or 10
        }
        labels = {
          **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
          **{
            "skycluster.io/public-subnet" = "true"
            "submariner.io/gateway" = "true"
          } if ng.publicAccess else {
            "skycluster.io/public-subnet" = "false"
          },
        }
        remoteAccess = {
          ec2SshKey = _xSetup?.status?.keypair?.id
          sourceSecurityGroupIdSelector = {
            matchLabels = {
              **helper._filter_default_labels(oxr.metadata.labels)
              "skycluster.io/secgroup-type" = "default",
            }
          }
        }
        instanceTypes = ng.instanceTypes or ["t3.medium"]
        subnetIdSelector.matchLabels = {
          "skycluster.io/public-subnet" = "true" if ng.publicAccess else "false"
          "skycluster.io/cluster-name" = oxr.metadata.name
        }
      }
    }
  }
}

_helper_subnet = lambda i, s {
  ec2v1beta1.Subnet{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        "skycluster.io/public-subnet" = "false" if s.type == "private" else "true",
        "skycluster.io/cluster-name" = oxr.metadata.name
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
        vpcIdSelector.matchLabels = {
          **helper._filter_default_labels(oxr.metadata.labels)
        }
        mapPublicIpOnLaunch = True if s.type == "public" else False,
      },
      providerConfigRef = {
        name = _provCfg.metadata.name,
      },
    }
  }
}

_helper_role_node_group = lambda s {
  iamv1beta1.Role{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/iam-role" = "nodegroup"
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name(s),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec: _defaults | {
      forProvider = {
        forceDetachPolicies = True
        managedPolicyArns = [
          "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
          "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
          "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
          "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        ]
        assumeRolePolicy = json.encode({
          Version = "2012-10-17",
          Statement = [
            {
              Effect = "Allow",
              Principal = {
                Service = ["ec2.amazonaws.com"]
              },
              Action = ["sts:AssumeRole"]
            }
          ]
        })
      }
    }
  }
}

_helper_route_table = lambda t {
  ec2v1beta1.RouteTable{
    metadata = {
      labels = {
        "skycluster.io/cluster-name" = oxr.metadata.name
        "skycluster.io/public-route-table" = "true" if t == "public" else "false",
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("{}-route-table".format("public" if t == "public" else "private")),
        **helper._is_paused_label(oxr.metadata.labels),
      }
    },
    spec = {
      forProvider = {
        region = _oxrProvRegion,
        vpcIdSelector.matchLabels = {
          **helper._filter_default_labels(oxr.metadata.labels)
        }
      },
      providerConfigRef = {
        name = _provCfg.metadata.name,
      },
    }
  }
}

_helper_route_table_association = lambda t {
  ec2v1beta1.RouteTableAssociation{
    metadata = {
      labels = {
        "skycluster.io/cluster-name" = oxr.metadata.name
        "skycluster.io/public-subnet" = "true" if t == "public" else "false",
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("{}-route-table-association".format("public" if t == "public" else "private")),
        **helper._is_paused_label(oxr.metadata.labels),
      }
    },
    spec = {
      forProvider = {
        region = _oxrProvRegion,
        routeTableIdSelector = {
          matchLabels = {
            "skycluster.io/cluster-name" = oxr.metadata.name
            "skycluster.io/public-route-table" = "true" if t == "public" else "false",
          },
        },
        subnetIdSelector = {
          matchLabels = {
            "skycluster.io/cluster-name" = oxr.metadata.name
            "skycluster.io/public-subnet" = "true" if t == "public" else "false",
          },
        },
      },
      providerConfigRef = {
        name = _provCfg.metadata.name,
      },
    }
  }
}

_helper_route = lambda t {
  ec2v1beta1.Route{
    metadata = {
      labels = {
        "skycluster.io/cluster-name" = oxr.metadata.name
        "skycluster.io/public-route-table" = "true" if t == "public" else "false",
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("{}-route".format("public" if t == "public" else "private")),
        **helper._is_paused_label(oxr.metadata.labels),
      }
    },
    spec = {
      forProvider = {
        destinationCidrBlock = "0.0.0.0/0",
        region = _oxrProvRegion,
        routeTableIdSelector = {
          matchLabels = {
            "skycluster.io/cluster-name" = oxr.metadata.name
            "skycluster.io/public-route-table" = "true" if t == "public" else "false",
          },
        },
        if t == "public":
          gatewayIdSelector.matchLabels = {
            # TODO
            **helper._filter_default_labels(oxr.metadata.labels)
          },
        if t == "private":
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
  }
}