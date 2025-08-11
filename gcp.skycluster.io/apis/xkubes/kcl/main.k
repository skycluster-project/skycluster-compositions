
import regex as re
import helper.v1alpha1.main as helper
import provider_gcp.compute.v1beta1 as compute_v1b1
import provider_gcp.compute.v1beta2 as compute_v1b2
import provider_gcp.cloudplatform.v1beta1 as cp_v1b1
import provider_gcp.container.v1beta1 as container_v1b1
import provider_helm.v1beta1 as helmv1b1
import provider_kubernetes.v1alpha1 as k8sv1a1

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

_ns = "skycluster-system"

assert _oxrProvRegion and _oxrProvZone and _oxrProvPlatform, \
  "Provider region, primary zone, platform must be specified"

_defaults = {
  deletionPolicy = "Delete"
  providerConfigRef.name = _provCfg.metadata.name
}


_items = []

_items += [
  cp_v1b1.ServiceAccount{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/composite-name" = _oxrName,
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("svcAcc"),
        **helper._is_paused_label(oxr.metadata.labels),
      }
    },
    spec = {
      forProvider = {
        displayName = _oxrName,
      },
      providerConfigRef = {
        name = _provCfg.metadata.name,
      },
    }
  },
  cp_v1b1.ServiceAccountKey{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/composite-name" = _oxrName,
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("svcAccKey"),
        **helper._is_paused_label(oxr.metadata.labels),
      }
    },
    spec = {
      forProvider = {
        serviceAccountIdSelector.matchControllerRef = True,
      },
      writeConnectionSecretToRef = {
        name = "{}-sakey".format(oxr.metadata.uid),
        namespace = _ns,
      }
      providerConfigRef = {
        name = _provCfg.metadata.name,
      }
    }
  }
]

_svcAccEmail = ocds?["svcAcc"]?.Resource?.status?.atProvider?.email
_project = ocds?["svcAcc"]?.Resource?.status?.atProvider?.id
_project = re.replace(_project, r"^projects/", "") if _project else Undefined
_project = re.replace(_project, r"/serviceAccounts/.*$", "") if _project else Undefined

_items += [
  cp_v1b1.ProjectIAMMember{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/composite-name" = _oxrName,
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("projectIamMember"),
        **helper._is_paused_label(oxr.metadata.labels),
      }
    },
    spec = {
      forProvider = {
        role = "roles/container.admin",
        member = "serviceAccount:{}".format(_svcAccEmail)
        project = _project
      },
      providerConfigRef = {
        name = _provCfg.metadata.name,
      },
    }
  }
] if (_svcAccEmail and _project) or ocds?["projectIamMember"] else []


# _project = ocds?["gkecluster"]?.Resource?.status?.atProvider?.project
_items += [
  container_v1b1.Cluster{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/composite-name" = _oxrName,
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("gkecluster"),
        **helper._is_paused_label(oxr.metadata.labels),
      }
    },
    spec = {
      forProvider = {
        deletionProtection = False,
        enableIntranodeVisibility = True,
        initialNodeCount = 1,
        ipAllocationPolicy = [
          {
            clusterSecondaryRangeName = "pods",
            servicesSecondaryRangeName = "services",
          }
        ]
        loggingService = "logging.googleapis.com/kubernetes",
        monitoringService = "monitoring.googleapis.com/kubernetes",
        location = _oxrProvRegion,
        networkSelector.matchLabels = {
          **helper._filter_labels(oxr.metadata.labels, ["provider-platform", "provider-region", "application-id"]) 
        }
        subnetworkSelector.matchLabels = {
          **helper._filter_labels(oxr.metadata.labels, ["provider-platform", "provider-region", "application-id"]),
          "skycluster.io/public-subnet" = "true"
        }
        nodeConfig = [
          {
            serviceAccount = _svcAccEmail
          }
        ]
        # nodeVersion "latest"
        # minMasterVersion = "latest"
        workloadIdentityConfig = [
          {
            workloadPool = "{}.svc.id.goog".format(_project) if _project else Undefined
          }
        ]
      },
      providerConfigRef = {
        name = _provCfg.metadata.name,
      },
      writeConnectionSecretToRef = {
        name = "{}-gkecluster".format(oxr.metadata.uid),
        namespace = _ns,
      },
    },
  }
] if (_project and _svcAccEmail) or ocds?["gkecluster"] else []

_nodeGroups = oxr.spec.nodeGroups
_nodeGroupsExists = any_true([ocds?["nodePool{}".format(i)] or False for i, _ in _nodeGroups])

_items += [
  container_v1b1.NodePool{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/composite-name" = _oxrName,
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("nodePool{}".format(i)),
        **helper._is_paused_label(oxr.metadata.labels),
      }
    },
    spec = {
      forProvider = {
        location = _oxrProvRegion,
        autoscaling = [
          {
            minNodeCount = ng.autoscaling?.minSize or 1,
            maxNodeCount = ng.autoscaling?.maxSize or 3,
          }
        ]
        clusterSelector.matchControllerRef = True
        initialNodeCount = 1
        management = [
          {
            autoRepair = True,
            autoUpgrade = True,
          }
        ]
        maxPodsPerNode = 55
        nodeConfig = [
          {
            diskSizeGb = 10,
            imageType = "COS_CONTAINERD",
            machineType = ng.instanceType or "e2-medium",
            metadata.disableLegacyEndpoints = "true",
            oauthScopes = [
              "https://www.googleapis.com/auth/cloud-platform"
            ],
            preemptible = True,
            shieldedInstanceConfig: [
              {
                enableIntegrityMonitoring = True,
                enableSecureBoot = True,
              }
            ]
            serviceAccount = _svcAccEmail,
          }
        ]
      },
      providerConfigRef = {
        name = _provCfg.metadata.name,
      },
    },
  } for i, ng in _nodeGroups
] if _svcAccEmail or _nodeGroupsExists else []

_providerConfigTypes = ["helm", "kubernetes"]
_items += [{
  apiVersion = "{}.crossplane.io/{}".format(t, "v1beta1" if t == "helm" else "v1alpha1")
  kind = "ProviderConfig"
  metadata = {
    annotations = {
      **helper._set_resource_name("providerConfig{}".format(t.capitalize()))
      "krm.kcl.dev/ready" = "True"
    }
  }
  spec = {
    credentials = {
      secretRef = {
        name = "{}-gkecluster".format(oxr.metadata.uid),
        namespace = _ns
        key = "kubeconfig"
      }
      source = "Secret"
    }
    identity = {
      secretRef = {
        name = "{}-sakey".format(oxr.metadata.uid),
        namespace = _ns
        key = "private_key"
      }
      source = "Secret"
      type = "GoogleApplicationCredentials"
    }
  }
} for t in _providerConfigTypes if helper._ready(ocds?["gkecluster"]) or ocds?["providerConfig{}".format(t.capitalize())]]

_items += [{
  apiVersion: "meta.krm.kcl.dev/v1alpha1"
  kind: "CompositeConnectionDetails"
  data: {
    kubeconfig = option("params")?.ocds?["gkecluster"]?.ConnectionDetails?.kubeconfig
  } if ocds?["gkecluster"] else {}
}]

_k8sProvCfgName = ocds?["gkeClusterConfig"]?.Resource?.metadata?.name 
_helmProvCfgName = ocds?["gkeClusterConfigHelm"]?.Resource?.metadata?.name 

_items += [
  k8sv1a1.ProviderConfig {
    metadata = {
      labels = {"skycluster.io/managed-by": "skycluster"}
      annotations = {
          **oxr.metadata?.annotations,
          **helper._set_resource_name("gkeClusterConfig"),
          "krm.kcl.dev/ready": "True"
      }
    }
    spec = {
      credentials = {
        source = "Secret"
        secretRef = {
          namespace = _ns
          name = "{}-gkecluster".format(oxr.metadata.uid)
          key = "kubeconfig"
        }
      }
      identity = {
        source = "Secret"
        type = "GoogleApplicationCredentials"
        secretRef = {
          namespace = _ns
          name = "{}-sakey".format(oxr.metadata.uid)
          key = "private_key"
        }
      }
    }
  }
] if helper._ready(ocds?["gkecluster"]) or ocds?["gkeClusterConfig"] else []

_items += [
    helmv1b1.ProviderConfig {
    metadata = {
      labels = {"skycluster.io/managed-by": "skycluster"}
      annotations = {
          **oxr.metadata?.annotations,
          **helper._set_resource_name("gkeClusterConfigHelm"),
          "krm.kcl.dev/ready": "True"
      }
    }
    spec = {
      credentials = {
        source: "Secret"
        secretRef = {
          namespace = _ns
          name = "{}-gkecluster".format(oxr.metadata.uid)
          key = "kubeconfig"
        }
      }
      identity = {
        source = "Secret"
        type = "GoogleApplicationCredentials"
        secretRef = {
          namespace = _ns
          name = "{}-sakey".format(oxr.metadata.uid)
          key = "private_key"
        }
      }
    }
  }
] if helper._ready(ocds?["gkecluster"]) or ocds?["gkeClusterConfigHelm"] else []


_items += [
  k8sv1a1.Object{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
        "skycluster.io/composite-name" = _oxrName,
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("workloadIdentitySettings"),
        **helper._is_paused_label(oxr.metadata.labels),
      }
      name = "{}-workload-identity-settings".format(_oxrName)
    }
    spec = {
      deletionPolicy = "Orphan"
      forProvider = {
        manifest = {
          apiVersion = "v1"
          kind = "ConfigMap"
          metadata = {
            name = "{}-workload-identity-settings".format(_oxrName)
            namespace = _ns
          }
          data = {
            gkeProject = _project
          }
        }
      }
      providerConfigRef = {
        name = _k8sProvCfgName
      }
    }
  } 
] if (helper._ready(ocds?["gkecluster"]) and _k8sProvCfgName) or ocds?["workloadIdentitySettings"] else []



dxr = {
  **option("params").dxr,
  # status.network = {
  #   privateIp = _privateAddress
  #   publicIp = _publicAddress
  # } if _privateAddress or _publicAddress else Undefined,
}

items = [*_items, dxr]