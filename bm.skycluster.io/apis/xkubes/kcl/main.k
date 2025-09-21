import yaml
import json
import base64
import helper.v1alpha1.main as helper
import provider_kubernetes.v1alpha2 as k8sv1a2

oxr = option("params").oxr # observed composite resource
ocds = option("params")?.ocds # observed composed resources
extra = option("params")?.extraResources

_default_labels = {
  **oxr.metadata?.labels,
  "skycluster.io/managed-by" = "skycluster"
}
_default_annotations = {**oxr.metadata?.annotations}

_ns = _skySetup.spec.namespace or "skycluster-system"

_oxrProvRegion = oxr.spec.providerRef.region
_oxrProvZone = oxr.spec.providerRef.zones?.primary
_oxrProvPlatform = oxr.spec.providerRef.platform
_oxrAppId = oxr.spec.applicationId or Undefined
assert _oxrProvRegion and _oxrProvZone and _oxrProvPlatform, \
  "Provider region, primary zone, platform must be specified"

assert oxr.metadata?.labels is not Undefined, "At least one label must be specified"
assert "skycluster.io/managed-by" in oxr.metadata.labels, "Label 'skycluster.io/managed-by' must be specified"

ctx = option("params")?.ctx
assert ctx is not Undefined, "Context must be provided in the params"

_extraRes = ctx["apiextensions.crossplane.io/extra-resources"]
assert _extraRes is not Undefined, "Extra resources must be provided in the context"

assert oxr.spec?.serviceCidr, "Service CIDR must be specified"
assert oxr.spec?.podCidr, "Pod CIDR must be specified"
assert oxr.spec?.nodes, "At least one node must be specified"

_initScriptsSSH = _extraRes["InitScriptsSSH"]
assert _initScriptsSSH, "Init scripts SSH must be provided in the extra resources"

_cms = _extraRes["ConfigMaps"][0]

_skySetup = _extraRes["SkySetups"][0]
assert _skySetup, "SkySetup resource must be provided in the extra resources"

_xSetup = _extraRes["XSetup"][0]
assert _xSetup, "XSetup resource must be provided in the extra resources"

_subnetCidr = _xSetup.status?.subnetCidr or Undefined
assert _subnetCidr, "Subnet CIDR must be specified in the XSetup status"

_k8sProvCfgName = _skySetup.status?.providerConfig?.kubernetes?.name or Undefined
assert _k8sProvCfgName, "Kubernetes provider config name must be specified in the SkySetup status"

_select_scripts: (any, [str]) -> any = lambda _scripts, names {
  _selected = [s \
    for s in _scripts \
      for n in names if s and n.lower() == s.metadata?.labels["skycluster.io/script-init"]
  ]
  assert len(_selected) == 1, "Expected exactly one script, found {}".format(len(_selected))
  _selected[0]
}

_K3sControllerScript = _select_scripts(_initScriptsSSH, ["bm-k3s-controller"])
assert _K3sControllerScript, "K3s controller main scripts must be provided in the context"

_k3sCtrlProbSc = _K3sControllerScript?.data?["k3s_controller_prob.sh"] or Undefined  
_k3sCtrlEnsureSc = _K3sControllerScript?.data?["k3s_controller.sh"] or Undefined
assert _k3sCtrlProbSc and _k3sCtrlEnsureSc, "K3s controller scripts must be provided in the context"

_K3sAgentScript = _select_scripts(_initScriptsSSH, ["k3s-agent"])
assert _K3sAgentScript, "K3s agent scripts must be provided in the context"

_k3sAgentProbSc = _K3sAgentScript?.data?["probeScript"] or Undefined
_k3sAgentEnsureSc = _K3sAgentScript?.data?["ensureScript"] or Undefined
assert _k3sAgentEnsureSc and _k3sAgentProbSc, "K3s agent scripts must be provided in the context"

assert oxr.spec.controlPlane?.deviceNodeName, "Control plane device node name must be specified"

_gatewayNodeStr = _cms.data?["gateway"] or Undefined
_workerNodesStr = _cms.data?["worker"] or Undefined

_gwNodes = yaml.decode(_gatewayNodeStr) if _gatewayNodeStr else Undefined
_workerNodes = yaml.decode(_workerNodesStr) if _workerNodesStr else []

#
# Only supporting one gateway node for now
#
_gwNodeName = oxr.spec.controlPlane?.deviceNodeName
assert _gwNodeName, "Gateway device name must be specified"
assert _gwNodeName in _gwNodes, "Gateway device name '{}' not found in the configmap".format(_gwNodeName)

_workerNodeNames = oxr.spec?.nodes or []
assert all_true([n in _workerNodesStr for n in _workerNodeNames]), \
  "Some worker device names not found in the configmap"

# Compare the node names with what is already in configmap
# and the xseup status's device nodes to ensure they match and ready

_provisionedGwNodes = {
  n.deviceName = n for n in _xSetup.status?.deviceNodes if n.type == "gateway"
}
_provisionedWorkerNodes = {
  n.deviceName = n for n in _xSetup.status?.deviceNodes if n.type == "worker"
}

# This is basically only one node for now
_gwNodesMap = {
  n = {
    **_gwNodes[n]
    sshProviderCfgName = _provisionedGwNodes[n]?.sshProviderConfigName
    sshSecretName = _provisionedGwNodes[n]?.sshSecretName
    ssh = { # secret (object) containing kubeconfig
      generate = "k3s-ctrl-{}".format(n)
      observed = ocds?[generate]?.Resource?.status?.atProvider?.manifest?.metadata?.name
    }
    secret = { # secret (object) containing kubeconfig
      generate = "sc-{}".format(n)
      observed = ocds?[generate]?.Resource?.status?.atProvider?.manifest?.metadata?.name
    }
    secretGate = all_true([
      ocds?[ssh?.generate]?.Resource?.status?.atProvider?.observed?.fields?.token,
      ocds?[ssh?.generate]?.Resource?.status?.atProvider?.observed?.fields?.kubeconfig,
    ])
  } for n in [_gwNodeName] \
      if _gwNodes and n in _gwNodes and n in _provisionedGwNodes
}

#
# Worker nodes Map
#
_workerNodesMap: {str:any} = {
  n = {
    **_workerNodes[n],
    sshProviderCfgName = _provisionedWorkerNodes[n]?.sshProviderConfigName,
    sshSecretName = _provisionedWorkerNodes[n]?.sshSecretName,
  } for n in _workerNodeNames \
      if _workerNodes and n in _workerNodes and n in _provisionedWorkerNodes
}


# # Depends on K3S controller installation
# # _k3sAgentEnsureSc = _k3sAgentEnsureSc.replace("__K3STOKEN__", _k3sToken)\
# #   .replace("__K3SHOSTIP__", _k3sHostIP)\
# #   .replace("__PROVIDERPLATFORM__", _oxrProvPlatform)\
# #   .replace("__REGION__", _oxrProvRegion)\
# #   .replace("__ZONE__", _oxrProvZone)


# Start assembling resources
_items = []

#
# For [gateway] node, we create a k3s controller installation task
#
_k3sCtrlEnsureSc = _k3sCtrlEnsureSc.replace("__SERVICE_CIDR__", oxr.spec.serviceCidr)\
  .replace("__CLUSTER_CIDR__", oxr.spec.podCidr)\
  .replace("__PROVIDERPLATFORM__", _oxrProvPlatform)\
  .replace("__REGION__", _oxrProvRegion)\
  .replace("__ZONE__", _oxrProvZone)

_items += [
  # s, pvCfgName, pbScript, ensScript
  _helper_ssh_task_k3s_ctrl(
      "k3s-ctrl-{}".format(n),
      spec.sshProviderCfgName,
      _k3sCtrlProbSc, _k3sCtrlEnsureSc) \
    for n, spec in _gwNodesMap \
      if spec.sshProviderCfgName and spec.sshSecretName or ocds?["k3s-ctrl-{}".format(n)]
] 

#
# Object: Controller ssh connection secret, it saves a secret containing k3s token and kubeconfig
# Multi controller is not yet supported
#
_items += [
  # s, PubIp, PrivIp, kubecfgB64, token
  _helper_cluster_secret(
    "k3s-sc-{}".format(n), spec.publicIp, spec.privateIp, 
    ocds?[spec.ssh.generate]?.Resource?.status?.atProvider?.observed?.fields.kubeconfig,
    ocds?[spec.ssh.generate]?.Resource?.status?.atProvider?.observed?.fields.token) \
    for n, spec in _gwNodesMap \
      if spec.secretGate or ocds?[spec.secret?.generate]
]

# #
# # ProviderConfig K8S: Controller Kubernetes provider config connection 
# # Multi controller is not yet supported
# #
# _items += [
#   k8sv1a2.Object{
#     "metadata" = {
#       labels = {"skycluster.io/managed-by" = "skycluster"}
#       annotations = {
#         **helper._set_resource_name(cv.providerConfigs?.k8s?.generate)
#       },
#     },
#     spec = {
#       references = [{
#         dependsOn = {
#           apiVersion = "v1"
#           kind = "Secret"
#           name = cv?.secret?.observed
#           namespace = _ns
#         }
#       }]
#       deletionPolicy = "Delete"
#       forProvider = {
#         manifest = {
#           apiVersion = "kubernetes.crossplane.io/v1alpha1",
#           kind = "ProviderConfig",
#           metadata = {
#             name = "k8s-os-{}".format(oxr.metadata.name),
#             namespace = _ns,
#             labels = {
#               "skycluster.io/managed-by" = "skycluster"
#               "skycluster.io/config-type" = "k8s-connection-data"
#               "skycluster.io/cluster-name" = _oxrName
#             },
#           },
#           spec = {
#             credentials = {
#               source = "Secret"
#               secretRef = {
#                 name = cv?.secret?.observed
#                 namespace = _ns,
#                 key = "kubeconfig"
#               }
#             }
#           }
#         },
#       },
#       providerConfigRef.name = _skyK8SProviderCfgName
#     }
#   } for c, cv in _ctrlObjData if cv.providerCfgGate or ocds?[cv.providerConfigs?.k8s?.generate]
# ]

# #
# # ProviderConfig Helm: Controller helm provider config connection 
# #
# _items += [
#   k8sv1a2.Object{
#     "metadata" = {
#       labels = {"skycluster.io/managed-by" = "skycluster"}
#       annotations = {
#         **helper._set_resource_name(cv.providerConfigs?.helm?.generate)
#       },
#     },
#     spec = {
#       references = [{
#         dependsOn = {
#           apiVersion = "v1"
#           kind = "Secret"
#           name = cv?.secret?.observed
#           namespace = _ns
#         }
#       }]
#       deletionPolicy = "Delete"
#       forProvider = {
#         manifest = {
#           apiVersion = "helm.crossplane.io/v1beta1",
#           kind = "ProviderConfig",
#           metadata = {
#             name = "k8s-os-{}".format(oxr.metadata.name),
#             namespace = _ns,
#             labels = {
#               "skycluster.io/managed-by" = "skycluster"
#               "skycluster.io/config-type" = "helm-connection-data"
#               "skycluster.io/cluster-name" = _oxrName
#             },
#           },
#           spec = {
#             credentials = {
#               source = "Secret"
#               secretRef = {
#                 name = cv?.secret?.observed
#                 namespace = _ns,
#                 key = "kubeconfig"
#               }
#             }
#           }
#         },
#       },
#       providerConfigRef.name = _skyK8SProviderCfgName
#     }
#   } for c, cv in _ctrlObjData if cv.providerCfgGate or ocds?[cv.providerConfigs?.helm?.generate]
# ]



# # extraItems = {
# #   apiVersion = "meta.krm.kcl.dev/v1alpha1"
# #   kind = "ExtraResources"
# #   requirements = {
# #     **{"bmPrivateKeySecrets" = {
# #         apiVersion: "v1",
# #         kind: "Secret",
# #         # we cannot use matchName because the secret is namespaced
# #         # hence we filter by label instead and check the name later
# #         matchLabels = {
# #           "skycluster.io/managed-by" = "skycluster",
# #           "skycluster.io/secret-type" = "onpremise-keypair"
# #         }
# #     }}
# #   }
# # }

dxr = {
  **option("params").dxr,
  status = {
    # log = json.encode({
    #   # gwNodes = _gwNodesMap,
    #   # workerNodes = _workerNodesMap,
    #   k3sData = [n for n in ocds?["k3s-ctrl-{}".format(n)] or []]
    # })
    serviceCidr = oxr.spec?.serviceCidr
    podCidr = oxr.spec?.podCidr
    # For easier access to cluster:
    # clusterSecretName = [v.secret?.observed for _, v in _ctrlObjData]?[0]
    controllers = [
      {
        privateIp = obj.privateIp or Undefined
        publicIp = obj.publicIp or Undefined
        providerConfigs = {
          k8s = ""
          ssh = obj.sshProviderCfgName or Undefined
          helm = ""
        }
        deviceNodeName = n
      } for n, obj in _gwNodesMap
    ]
    agents = [
      {
        deviceNodeName = n
        providerConfigs = {
          ssh = obj.sshProviderCfgName or Undefined
        }
        privateIp = obj.privateIp or Undefined
      } for n, obj in _workerNodesMap
    ]
  }
}

# Collect all resources into a list for output
items = [*_items, dxr]


# Helper to install and setup tailscale
_helper_ssh_task_k3s_ctrl = lambda s, pvCfgName, pbScript, ensScript {
  {
    apiVersion = "ssh.crossplane.io/v1alpha1"
    kind = "SSHTask"
    metadata = {
      labels = _default_labels
      annotations = _default_annotations | {
        **helper._set_resource_name(s),
      },
    },
    spec = {
      providerConfigRef.name = pvCfgName
      forProvider = {
        scripts = {
          probeScript.inline = pbScript
          ensureScript.inline = ensScript
        }
        observe = {
          refreshPolicy = "Always"
          capture = "both"
          "map" = [
            {
              from = "kubeconfig.token"
              to = "token"
            }
            {
              from = "kubeconfig.encoded"
              to = "kubeconfig"
            }
            {
              from = "network.interface"
              to = "interface"
            }
            {
              from = "network.ip"
              to = "ip"
            }
          ]
        }
        execution = {
          sudo = True
          shell = "/bin/bash -euo pipefail"
          timeoutSeconds = 600
          # TODO: change and check setting to 10 to improve speed of convergence
          maxAttempts = 2
        }
        artifactPolicy.capture = "both"    
      }
    }
  }
}

_helper_cluster_secret = lambda s, PubIp, PrivIp, kubecfgB64, token {
  k8sv1a2.Object{
    metadata = {
      labels = _default_labels
      annotations = _default_annotations | {
        **helper._set_resource_name(s),
      },
    },
    spec = {
      deletionPolicy = "Delete"
      forProvider = {
        manifest = {
          apiVersion = "v1",
          kind = "Secret",
          metadata = {
            name = "k3s-bm-{}-{}".format(_oxrProvRegion.lower(), PubIp.replace(".","-")),
            namespace = _ns,
            labels = _default_labels | {
              "skycluster.io/secret-type" = "k8s-connection-data",
              "skycluster.io/cluster-name" = oxr.metadata.name,
              "skycluster.io/provider-platform" = "baremetal"
            },
            annotations = _default_annotations | {
              "skycluster.io/public-ip" = PubIp,
              "skycluster.io/private-ip" = PrivIp,
            },
          },
          "type" = "Opaque",
          data = {
            "kubeconfig" = base64.encode(base64.decode(kubecfgB64).replace(PrivIp, PubIp)) \
              if PrivIp and PubIp else kubecfgB64,
            "token" = base64.encode(token)
          }
        },
      },
      providerConfigRef.name = _k8sProvCfgName
    }
  }
}