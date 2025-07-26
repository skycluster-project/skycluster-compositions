import json
import crypto
import regex
import helper.v1alpha1.main as helper
import provider_kubernetes.v1alpha1 as k8sv1alpha1
import provider_helm.v1alpha1 as helmv1alpha1
import provider_aws.eks.v1beta1 as eksv1beta1
import provider_aws.eks.v1beta2 as eksv1beta2
import provider_aws.iam.v1beta1 as iamv1beta1
import provider_aws.sqs.v1beta1 as sqsv1beta1
import provider_aws.cloudwatchevents.v1beta1 as cwev1beta1

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
_ns = _skySetup.spec.namespace

_defaults = {
  deletionPolicy = "Delete"
  providerConfigRef.name = _provCfg.metadata.name
}

_items = []

_items += [
  iamv1beta1.Role {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/iam-role" = "controlplane"
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("controlplaneRole"),
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
  },

  eksv1beta2.Cluster {
    metadata = {
      labels = {
        **oxr.metadata?.labels
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("kubernetesCluster"),
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
            }
          }
          subnetIdSelector.matchLabels = {
            **helper._filter_labels(oxr.metadata.labels, ["provider-platform", "provider-region", "application-id"]) 
          }
        }
      }
    }
  }
]

# _clusterSecurityGroupId = ocds?.kubernetesCluster?.Resource?.status?.atProvider?.vpcConfig?.clusterSecurityGroupId or False
# _items += [
#   ec2v1beta1.SecurityGroup {
#     metadata = {
#       annotations = {
#         **helper._set_resource_name("clusterSecurityGroupImport")
#         "crossplane.io/external-name" = _clusterSecurityGroupId
#       }
#     }
#     spec: _defaults | {
#       forProvider = {
#         region = _oxrProvRegion
#         tags = {
#           # TODO: is skycluster the right value here?
#           "eks.aws.platform.upbound.io/discovery" = "skycluster"
#         }
#       }
#     }
#   }
# ] if _clusterSecurityGroupId else []

_connectionSecretNamespace = _ns

_items += [
  eksv1beta1.ClusterAuth{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId)
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("kubernetesClusterAuth"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec: _defaults | {
      forProvider = {
        region = _oxrProvRegion
        clusterNameSelector.matchControllerRef = True
      }
      writeConnectionSecretToRef = {
        name = "{}-eks".format(oxr.metadata.uid)
        namespace = _connectionSecretNamespace
      }
    }
  }
] if helper._ready(ocds?["kubernetesCluster"]) or ocds?["kubernetesClusterAuth"] else []


_nodeGroups = oxr.spec.nodeGroups
_items += [
  # The public node group is used to create nodes acting as gateways for the cluster.
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
          maxSize = ng.autoScaling?.maxSize or 10
          minSize = ng.autoScaling?.minSize or 1
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
        instanceTypes = ng.instanceTypes or ["t3.medium"]
        subnetIdSelector.matchLabels = {
          **helper._filter_labels(oxr.metadata.labels, ["provider-platform", "provider-region", "application-id"])
          "skycluster.io/public-subnet" = "true" if ng.publicAccess else "false"
        }
      }
    }
  }
  for i, ng in _nodeGroups
] if helper._ready(ocds?["vpc-cni-addon"]) or ocds?["nodeGroupPublic"] else []

_items += [
  iamv1beta1.Role{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/iam-role" = "nodegroup"
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("nodegroupRole"),
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
]



_principalArn = oxr.spec?.principalArn or Undefined

_items += [
  eksv1beta1.AccessEntry{
    # force recreate when principalArn changes
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name(crypto.sha256("accessEntry-{}".format(_principalArn))),
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
        principalArn = _principalArn
      }
    }
  },
  eksv1beta1.AccessPolicyAssociation{
    # force recreate when principalArn changes
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name(crypto.sha256("accessPolicyAssociation-{}".format(_principalArn))),
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
] if _principalArn else []


_items += [
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
] if helper._ready(ocds?["kubernetesClusterAuth"]) or ocds?["vpc-cni-addon"] else []


_nodeGroupReady = any_true(
  [helper._ready(ocds?["nodeGroup{}{}".format("Public" if ng.publicAccess else "Private", i)] ) for i, ng in _nodeGroups]
)
_items += [
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
] if _nodeGroupReady or ocds?["aws-ebs-csi-driver-addon"] else []


_items += [
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
] if _nodeGroupReady or ocds?["eks-pod-identity-agent"] else []

_providerConfigTypes = ["helm", "kubernetes"]
_items += [{
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
      name = "{}-eks".format(oxr.metadata.uid)
      namespace = _connectionSecretNamespace
      key = "kubeconfig"
    }
    source = "Secret"
  }
} for t in _providerConfigTypes if helper._ready(ocds?["kubernetesClusterAuth"]) or ocds?["providerConfig{}".format(t.capitalize())]]

_items += [{
  apiVersion: "meta.krm.kcl.dev/v1alpha1"
  kind: "CompositeConnectionDetails"
  data: {
    kubeconfig = option("params")?.ocds?["kubernetesClusterAuth"]?.ConnectionDetails?.kubeconfig
  } if ocds?["kubernetesClusterAuth"] else {}
}]


_items += [
  # Create IAM Role for Karpenter node instances
  iamv1beta1.Role {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/iam-role" = "karpenter"
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("instanceNodeRole"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec = {
      **_defaults
      forProvider = {
        assumeRolePolicy = json.encode({
          Version = "2012-10-17",
          Statement = [
            {
              Effect = "Allow",
              Principal = {
                Service = [
                  "ec2.amazonaws.com"
                ]
              },
              Action = [
                "sts:AssumeRole"
              ]
            }
          ]
        })
      }
    }
  }
]

_items += [
  # Attach EKS Policy
  iamv1beta1.RolePolicyAttachment {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("instanceNodeRoleEKSPolicy"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec = {
      **_defaults
      forProvider = {
        policyArn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
        roleSelector = {
          matchControllerRef = True
          matchLabels = {"skycluster.io/iam-role": "karpenter"}
        }
      }
    }
  }
  # Attach CNI Policy
  iamv1beta1.RolePolicyAttachment {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("InstanceNodeRoleCNIPolicy"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec = {
      **_defaults
      forProvider = {
        policyArn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
        roleSelector = {
          matchControllerRef = True
          matchLabels = {"skycluster.io/iam-role": "karpenter"}
        }
      }
    }
  }
  # Attach ECR Policy
  iamv1beta1.RolePolicyAttachment {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("instanceNodeRoleECRPolicy"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec = {
      **_defaults
      forProvider = {
        policyArn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        roleSelector = {
          matchControllerRef = True
          matchLabels = {"skycluster.io/iam-role": "karpenter"}
        }
      }
    }
  }
  # Attach SSM Policy
  iamv1beta1.RolePolicyAttachment {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("instanceNodeRoleSSMPolicy"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec = {
      **_defaults
      forProvider = {
        policyArn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
        roleSelector = {
          matchControllerRef = True
          matchLabels = {"skycluster.io/iam-role": "karpenter"}
        }
      }
    }
  }
] if ocds?["instanceNodeRole"] else []


_items += [
  # Create Instance Profile
  iamv1beta1.InstanceProfile {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("instanceProfile"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec = {
      **_defaults
      forProvider = {
        roleSelector = {
          matchControllerRef = True
          matchLabels = {"skycluster.io/iam-role": "karpenter"}
        }
      }
    }
  },
]

_items += [
  # Create AccessEntry for Karpenter role
  # Note: If we use type here, clusterNameSelector will conflict and
  # we cannot forward the selector to the object
  eksv1beta1.AccessEntry {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("karpenterAccessEntry"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    # _metadata("accessEntry")
    spec = {
      **_defaults
      forProvider = {
        region = _oxrProvRegion
        type = "EC2_LINUX"
        clusterNameSelector = {
          matchControllerRef = True
        }
        kubernetesGroups = []
        principalArnFromRoleSelector = {
          matchControllerRef = True
          matchLabels = {"skycluster.io/iam-role": "karpenter"}
        }
      }
      managementPolicies = ["*"]
    }
  }
] if helper._ready(ocds?["kubernetesCluster"]) or ocds?["karpenterAccessEntry"] else []


_statusClusterName = ocds?["kubernetesCluster"]?.Resource?.status?.atProvider?.clusterName
_sqsQueueName = "karpenter-{}".format(_statusClusterName) if _statusClusterName else Undefined
_statusSqsQueueArn = ocds?["sqsQueue"]?.Resource?.status?.atProvider?.arn or Undefined
_statusInstanceNodeRoleArn = ocds?["instanceNodeRole"]?.Resource?.status?.atProvider?.arn or Undefined
_instanceNodeRolArn = ocds?["instanceNodeRole"]?.Resource?.status?.atProvider?.arn or Undefined
_statusAccountId = regex.replace(
  _instanceNodeRolArn, 
  "arn:aws:iam::(\d+):.*", 
  "$1"
) if _instanceNodeRolArn else Undefined

_items += [
  iamv1beta1.Role{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/iam-role" = "podIdentity"
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("karpenterRole"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec = _defaults | {
      forProvider = {
        inlinePolicy = [
          {
            name = "default"
            policy = json.encode({
              "Version" = "2012-10-17"
              "Statement" = [
                {
                  "Sid" = "AllowScopedEC2InstanceActions"
                  "Effect" = "Allow"
                  "Resource" = [
                    "arn:aws:ec2:${_oxrProvRegion}::image/*"
                    "arn:aws:ec2:${_oxrProvRegion}::snapshot/*"
                    "arn:aws:ec2:${_oxrProvRegion}:*:spot-instances-request/*"
                    "arn:aws:ec2:${_oxrProvRegion}:*:security-group/*"
                    "arn:aws:ec2:${_oxrProvRegion}:*:subnet/*"
                  ]
                  "Action" = [
                    "ec2:RunInstances"
                    "ec2:CreateFleet"
                  ]
                }
                {
                  "Sid" = "AllowScopedEC2LaunchTemplateAccessActions"
                  "Effect" = "Allow"
                  "Resource" = "arn:aws:ec2:${_oxrProvRegion}:*:launch-template/*"
                  "Action" = [
                    "ec2:RunInstances"
                    "ec2:CreateFleet"
                  ]
                  "Condition" = {
                    "StringEquals" = {
                      "aws:ResourceTag/kubernetes.io/cluster/${_statusClusterName}" = "owned"
                    }
                    "StringLike" = {
                      "aws:ResourceTag/karpenter.sh/nodepool" = "*"
                    }
                  }
                }
                {
                  "Sid" = "AllowScopedEC2InstanceActionsWithTags"
                  "Effect" = "Allow"
                  "Resource" = [
                    "arn:aws:ec2:${_oxrProvRegion}:*:fleet/*"
                    "arn:aws:ec2:${_oxrProvRegion}:*:instance/*"
                    "arn:aws:ec2:${_oxrProvRegion}:*:volume/*"
                    "arn:aws:ec2:${_oxrProvRegion}:*:network-interface/*"
                    "arn:aws:ec2:${_oxrProvRegion}:*:launch-template/*"
                    "arn:aws:ec2:${_oxrProvRegion}:*:spot-instances-request/*"
                  ]
                  "Action" = [
                    "ec2:RunInstances"
                    "ec2:CreateFleet"
                    "ec2:CreateLaunchTemplate"
                  ]
                  "Condition" = {
                    "StringEquals" = {
                      "aws:RequestTag/kubernetes.io/cluster/${_statusClusterName}" = "owned"
                      "aws:RequestTag/eks:eks-cluster-name" = _statusClusterName
                    }
                    "StringLike" = {
                      "aws:RequestTag/karpenter.sh/nodepool" = "*"
                    }
                  }
                }
                {
                  "Sid" = "AllowScopedResourceCreationTagging"
                  "Effect" = "Allow"
                  "Resource" = [
                    "arn:aws:ec2:${_oxrProvRegion}:*:fleet/*"
                    "arn:aws:ec2:${_oxrProvRegion}:*:instance/*"
                    "arn:aws:ec2:${_oxrProvRegion}:*:volume/*"
                    "arn:aws:ec2:${_oxrProvRegion}:*:network-interface/*"
                    "arn:aws:ec2:${_oxrProvRegion}:*:launch-template/*"
                    "arn:aws:ec2:${_oxrProvRegion}:*:spot-instances-request/*"
                  ]
                  "Action" = "ec2:CreateTags"
                  "Condition" = {
                    "StringEquals" = {
                      "aws:RequestTag/kubernetes.io/cluster/${_statusClusterName}" = "owned"
                      "aws:RequestTag/eks:eks-cluster-name" = _statusClusterName
                      "ec2:CreateAction" = [
                        "RunInstances"
                        "CreateFleet"
                        "CreateLaunchTemplate"
                      ]
                    }
                    "StringLike" = {
                      "aws:RequestTag/karpenter.sh/nodepool" = "*"
                    }
                  }
                }
                {
                  "Sid" = "AllowScopedResourceTagging"
                  "Effect" = "Allow"
                  "Resource" = "arn:aws:ec2:${_oxrProvRegion}:*:instance/*"
                  "Action" = "ec2:CreateTags"
                  "Condition" = {
                    "StringEquals" = {
                      "aws:ResourceTag/kubernetes.io/cluster/${_statusClusterName}" = "owned"
                    }
                    "StringLike" = {
                      "aws:ResourceTag/karpenter.sh/nodepool" = "*"
                    }
                    "StringEqualsIfExists" = {
                      "aws:RequestTag/eks:eks-cluster-name" = _statusClusterName
                    }
                    "ForAllValues:StringEquals" = {
                      "aws:TagKeys" = [
                        "eks:eks-cluster-name"
                        "karpenter.sh/nodeclaim"
                        "Name"
                      ]
                    }
                  }
                }
                {
                  "Sid" = "AllowScopedDeletion"
                  "Effect" = "Allow"
                  "Resource" = [
                    "arn:aws:ec2:${_oxrProvRegion}:*:instance/*"
                    "arn:aws:ec2:${_oxrProvRegion}:*:launch-template/*"
                  ]
                  "Action" = [
                    "ec2:TerminateInstances"
                    "ec2:DeleteLaunchTemplate"
                  ]
                  "Condition" = {
                    "StringEquals" = {
                      "aws:ResourceTag/kubernetes.io/cluster/${_statusClusterName}" = "owned"
                    }
                    "StringLike" = {
                      "aws:ResourceTag/karpenter.sh/nodepool" = "*"
                    }
                  }
                }
                {
                  "Sid" = "AllowRegionalReadActions"
                  "Effect" = "Allow"
                  "Resource" = "*"
                  "Action" = [
                    "ec2:DescribeAvailabilityZones"
                    "ec2:DescribeImages"
                    "ec2:DescribeInstances"
                    "ec2:DescribeInstanceTypeOfferings"
                    "ec2:DescribeInstanceTypes"
                    "ec2:DescribeLaunchTemplates"
                    "ec2:DescribeSecurityGroups"
                    "ec2:DescribeSpotPriceHistory"
                    "ec2:DescribeSubnets"
                  ]
                  "Condition" = {
                    "StringEquals" = {
                      "aws:RequestedRegion" = _oxrProvRegion
                    }
                  }
                }
                {
                  "Sid" = "AllowSSMReadActions"
                  "Effect" = "Allow"
                  "Resource" = "arn:aws:ssm:${_oxrProvRegion}::parameter/aws/service/*"
                  "Action" = "ssm:GetParameter"
                }
                {
                  "Sid" = "AllowPricingReadActions"
                  "Effect" = "Allow"
                  "Resource" = "*"
                  "Action" = "pricing:GetProducts"
                }
                {
                  "Sid" = "AllowInterruptionQueueActions"
                  "Effect" = "Allow"
                  "Resource" = _statusSqsQueueArn
                  "Action" = [
                    "sqs:DeleteMessage"
                    "sqs:GetQueueUrl"
                    "sqs:ReceiveMessage"
                  ]
                }
                {
                  "Sid" = "AllowPassingInstanceRole"
                  "Effect" = "Allow"
                  "Resource" = _statusInstanceNodeRoleArn
                  "Action" = "iam:PassRole"
                  "Condition" = {
                    "StringEquals" = {
                      "iam:PassedToService" = "ec2.amazonaws.com"
                    }
                  }
                }
                {
                  "Sid" = "AllowAPIServerEndpointDiscovery"
                  "Effect" = "Allow"
                  "Resource" = "arn:aws:eks:${_oxrProvRegion}:${_statusAccountId}:cluster/${_statusClusterName}"
                  "Action" = "eks:DescribeCluster"
                }
              ]
            })
            }
          ]
        # if inlinePolicy:
        #   inlinePolicy = inlinePolicy
        # if permissionBoundaryArn:
        #   permissionsBoundary = permissionBoundaryArn
        # if managedPolicyArns:
        #   managedPolicyArns = managedPolicyArns
        assumeRolePolicy = json.encode({
          Version = "2012-10-17",
          Statement = [
            {
              Sid      = "AllowEksAuthToAssumeRoleForPodIdentity",
              Effect   = "Allow",
              Principal = {
                Service = "pods.eks.amazonaws.com"
              },
              Action = [
                "sts:AssumeRole",
                "sts:TagSession"
              ]
            }
          ]
        })
      }
    }
  },
  eksv1beta1.PodIdentityAssociation{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        # "skycluster.io/iam-role" = "karpenter"
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("podIdentityAssociation"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    # _metadata("podIdentityAssociation")
    spec = _defaults | {
      forProvider = {
        region = _oxrProvRegion
        roleArnSelector: {
          matchLabels = {
            "skycluster.io/iam-role": "podIdentity"
          }
        }
        clusterNameSelector.matchControllerRef = True
        serviceAccount = "karpenter"
        namespace = "karpenter"
      }
    }
  }
] if _statusClusterName and _statusAccountId and _statusSqsQueueArn and _statusInstanceNodeRoleArn else []

_items += [
  # Create SQS Queue for Karpenter
  sqsv1beta1.Queue {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("sqsQueue"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec = {
      **_defaults
      forProvider = {
        region = _oxrProvRegion
        name = _sqsQueueName
        messageRetentionSeconds = 300
      }
    }
  },
] if helper._ready(ocds?["kubernetesCluster"]) or ocds?["sqsQueue"] else []

_items += [
  # Create Cloudwatch Event Rules
  # Health Event Rule
  cwev1beta1.Rule {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        # "crossplane.io/composite": _id, 
        "skycluster.io/iam-role": "HealthEvent"
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("ruleHealthEvent"),
        **helper._is_paused_label(oxr.metadata.labels)
        # "crossplane.io/external-name" = _healthEventName
      }
      # generateName = "${_id}-"
      # labels = {"crossplane.io/composite": _id, "type": "HealthEvent"}
      # name = _healthEventName
    }
    spec = {
      forProvider = {
        region = _oxrProvRegion
        eventBusName = "default"
        eventPattern = json.encode({
          source = ["aws.health"],
          "detail-type" = ["AWS Health Event"]
        })
      }
    }
  }
  # Instance Rebalance Rule
  cwev1beta1.Rule {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/iam-role": "InstanceRebalance"
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("ruleInstanceRebalance"),
        **helper._is_paused_label(oxr.metadata.labels),
        # "crossplane.io/composite": _id, 
        # "crossplane.io/external-name" = _instanceRebalanceName
      }
      # annotations: {
      #   "crossplane.io/external-name" = _instanceRebalanceName
      # }
      # generateName = "${_id}-"
      # labels = {"crossplane.io/composite": _id, "type": "InstanceRebalance"}
      # name = _instanceRebalanceName
    }
    spec = {
      forProvider = {
        region = _oxrProvRegion
        eventBusName = "default"
        eventPattern = json.encode({
          source = ["aws.ec2"],
          "detail-type" = ["EC2 Instance Rebalance Recommendation"]
        })
      }
    }
  }
  # Instance State Change Rule
  cwev1beta1.Rule {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/iam-role": "InstanceStateChange"
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("ruleInstanceStateChange"),
        **helper._is_paused_label(oxr.metadata.labels)
        # "crossplane.io/external-name" = _instanceStateChangeName
      }
      # annotations: {
      #   "crossplane.io/external-name" = _instanceStateChangeName
      # }
      # generateName = "${_id}-"
      # labels = {"crossplane.io/composite": _id, "type": "InstanceStateChange"}
      # name = _instanceStateChangeName
    }
    spec = {
      forProvider = {
        region = _oxrProvRegion
        eventBusName = "default"
        eventPattern = json.encode({
          source = ["aws.ec2"]
          "detail-type" = ["EC2 Instance State-change Notification"]
        })
      }
    }
  }
  # Spot Interrupt Rule
  cwev1beta1.Rule {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/iam-role": "SpotInterrupt"
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("ruleSpotInterrupt"),
        **helper._is_paused_label(oxr.metadata.labels)  
        # "crossplane.io/external-name" = _spotInterruptName
      }
      # annotations: {
      #   "crossplane.io/external-name" = _spotInterruptName
      # }
      # generateName = "${_id}-"
      # labels = {"crossplane.io/composite": _id, "type": "SpotInterrupt"}
      # name = _spotInterruptName
    }
    spec = {
      forProvider = {
        region = _oxrProvRegion
        eventBusName = "default"
        eventPattern = json.encode({
          source = ["aws.ec2"],
          "detail-type" = ["EC2 Spot Instance Interruption Warning"]
        })
      }
    }
  }
]

_items += [
  # Create Karpenter Helm Chart Release
  helmv1alpha1.Release{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("karpenterChart"),
        **helper._is_paused_label(oxr.metadata.labels)  
        # "crossplane.io/external-name" = "karpenter"
      }
      # generateName = "${_id}-"
    }
    spec = {
      deletionPolicy = "Orphan"
      forProvider = {
        wait = True
        chart = {
          name = "karpenter"
          repository = "oci://public.ecr.aws/karpenter"
          version = "1.0.0"
        }
        namespace = "karpenter"
        values = {
          settings = {
            clusterName = _statusClusterName
            interruptionQueueName = ocds?["sqsQueue"]?.Resource?.status?.atProvider?.name
          }
        }
      }
      providerConfigRef = {
        name = "providerConfig{}".format("Helm")
      }
    }
  }
] if (_statusClusterName and ocds?["sqsQueue"]?.Resource?.status?.atProvider?.name) or ocds?["karpenterChart"] else []

_instanceProfileArn = ocds?["instanceProfile"]?.Resource?.status?.atProvider?.arn
_statusInstanceProfileName = regex.replace(
  _instanceProfileArn,
  "arn:aws:iam::\\d+:instance-profile/(.+)",
  "$1"
) if _instanceProfileArn else Undefined

_items += [
  # Create EC2NodeClass for Karpenter
  k8sv1alpha1.Object {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("karpenterNodeClass"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec = {
      deletionPolicy = "Orphan"
      forProvider = {
        manifest = {
          apiVersion = "karpenter.k8s.aws/v1"
          kind = "EC2NodeClass"
          metadata = {
            name = "default"
          }
          spec = {
            amiFamily = "AL2"
            amiSelectorTerms = [
              {
                alias = "al2@latest"
              }
            ]
            tags = {
              KarpenterNodePoolName = "default"
              NodeType = "default"
              intent = "apps"
              "karpenter.sh/discovery" = _statusClusterName
              **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
            }
            subnetSelectorTerms = [
              {
                tags = {
                  **helper._filter_labels(oxr.metadata.labels, ["provider-platform", "provider-region", "application-id"]),
                  "skycluster.io/public-subnet": "false",
                }
              }
            ]
            securityGroupSelectorTerms = [
              {
                tags = helper._filter_default_labels(oxr.metadata.labels)
              }
            ]
            instanceProfile = _statusInstanceProfileName
          }
        }
      }
      providerConfigRef = {
        name = "providerConfig{}".format("Kubernetes")
      }
    }
  }
] if (_statusClusterName and _statusInstanceProfileName) or ocds?["karpenterNodeClass"] else []

_items += [
  # Create NodePool for Karpenter
  k8sv1alpha1.Object {
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("karpenterNodePool"),
        **helper._is_paused_label(oxr.metadata.labels)
      }
    }
    spec = {
      deletionPolicy = "Orphan"
      forProvider = {
        manifest = {
          apiVersion = "karpenter.sh/v1"
          kind = "NodePool"
          metadata = {
            name = "default"
          }
          spec = {
            disruption = {
              consolidateAfter = "1m"
              consolidationPolicy = "WhenEmptyOrUnderutilized"
            }
            limits = {
              cpu = 1000
              memory = "500Gi"
            }
            template = {
              metadata = {
                labels = {
                  intent = "apps"
                }
              }
              spec = {
                nodeClassRef = {
                  group = "karpenter.k8s.aws"
                  kind = "EC2NodeClass"
                  name = "default"
                }
                requirements = [
                  {
                    key = "karpenter.k8s.aws/instance-category"
                    operator = "In"
                    values = [
                      "c"
                      "m"
                      "r"
                      "i"
                      "d"
                    ]
                  }
                  {
                    key = "karpenter.k8s.aws/instance-cpu"
                    operator = "In"
                    values = [
                      "4"
                      "8"
                      "16"
                      "32"
                      "48"
                      "64"
                    ]
                  }
                  {
                    key = "karpenter.sh/capacity-type"
                    operator = "In"
                    values = [
                      "spot"
                      "on-demand"
                    ]
                  }
                  {
                    key = "kubernetes.io/arch"
                    operator = "In"
                    values = [
                      "amd64"
                      "arm64"
                    ]
                  }
                ]
              }
            }
          }
        }
      }
      providerConfigRef = {
        name = "providerConfig{}".format("Kubernetes")
      }
    }
  }
] if _statusInstanceProfileName or ocds?["karpenterNodePool"] else []


# items += [
#   helmv1alpha1.Release{
#     metadata = {
#       labels = {
#         **oxr.metadata?.labels,
#         **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
#       }
#       annotations = {
#         **oxr.metadata?.annotations,
#         **helper._set_resource_name("submarinerClient"),
#         **helper._is_paused_label(oxr.metadata.labels)
#       }
#     }
#     spec = {
#       forProvider = {
#         wait = True
#         chart = {
#           name = "submariner-operator"
#           repository = "https://submariner-io.github.io/submariner-charts/charts"
#           version: "0.20.1"
#         }
#         namespace = "submariner-operator"
#         values = {
#           ipsec.psk = "submariner-psk"
#           broker = {
#             server = "broker.submariner-operator.svc"
#             token = "submariner-token"
#             namespace = "submariner-operator"
#             ca = "submariner-ca"
#           }
#           submariner = {
#             cableDriver = "wireguard"
#             clusterId = "submariner-cluster"
#             clusterCidr = "10.0.0.0/16"
#             serviceCidr = "10.0.1.0/24"
#             natEnabled = "true"
#           }
#         }
#       }
#       providerConfigRef = {
#         name = "providerConfig{}".format("Helm")
#       }
#     }
#   } if _principalArn else []
# ]


# submarinerBroker = helmv1alpha1.Release {
#   metadata = {
#     labels = {
#       **oxr.metadata?.labels,
#       **helper._filter_labels(oxr.metadata.labels, ["managed-by"]),
#     }
#     annotations = {
#       **oxr.metadata?.annotations,
#       **helper._set_resource_name("submarinerBroker"),
#       **helper._is_paused_label(oxr.metadata.labels)
#     }
#   }
#   spec = {
#     forProvider = {
#       wait = True
#       chart = {
#         name = "submariner-k8s-broker"
#         repository = "https://submariner-io.github.io/submariner-charts/charts"
#         version: "0.20.1"
#       }
#       namespace = "submariner-k8s-broker"
#     }
#     providerConfigRef = {
#       name = "provider-kubernetes"
#     }
#   }
# }

# _submarinerBrokerStatus = ocds?["submarinerBroker"].Resource?.status?.atProvider?.status or Undefined

# k8s = k8sv1alpha1.Object{
#   metadata = {
#     labels = {
#       **oxr.metadata?.labels,
#       **helper._filter_labels(oxr.metadata.labels, ["managed-by"]),
#     }
#     annotations = {
#       **oxr.metadata?.annotations,
#       **helper._set_resource_name("submarinerBrokerConfigmap"),
#       **helper._is_paused_label(oxr.metadata.labels)
#     }
#   }
#   spec = {
#     forProvider = {
#       manifest = {
#         apiVersion = "v1"
#         kind = "ConfigMap"
#         metadata = {
#           name = "submariner-broker"
#           namespace = "submariner-operator"
#         }
#         data = {
#           values.yaml = """
# ipsec:
#   psk: "<SUBMARINER_PSK>"
# broker:
#   server: "<SUBMARINER_BROKER_URL>"
#   token: "<SUBMARINER_BROKER_TOKEN>"
#   namespace: "<BROKER_NS>"
#   ca: "<SUBMARINER_BROKER_CA>"
# submariner:
#   serviceDiscovery: false
#   cableDriver: wireguard
#   clusterId: "<CLUSTER_ID>"
#   clusterCidr: "<CLUSTER_CIDR>"
#   serviceCidr: "<SERVICE_CIDR>"
#   natEnabled: true
# """
#         }
#       }
#     }
#     providerConfigRef = {
#       name = "provider-kubernetes"
#     }
#   }
# }

items =  _items


