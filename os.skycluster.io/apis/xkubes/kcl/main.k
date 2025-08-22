#
# XKube object creates an un-managed Kubernetes cluster.
# 
# List of objects:
#  - XKube
#    Controllers:
#    - XInstance
#      Secret (k3s)
#      SSHTask (fetch k3s token)
#    Agents:
#    - XInstance
#      SSHTask (ensure joining k3s controller)


import yaml
import base64
import json
import crypto
import helper.v1alpha1.main as helper
import provider_kubernetes.v1alpha2 as k8sv1a2
import provider_kubernetes.v1alpha1 as k8sv1a1

oxr = option("params").oxr # observed composite resource
ocds = option("params")?.ocds # observed composed resources

ctx = option("params")?.ctx
assert ctx is not Undefined, "Context must be provided in the params"

_extraRes = ctx["apiextensions.crossplane.io/extra-resources"]
assert _extraRes is not Undefined, "Extra resources must be provided in the context"

_xsetup = _extraRes["XSetup"][0]
assert _xsetup is not Undefined, "XSetup must be provided in the extra resources"

_skySetup = _extraRes["SkySetups"][0]
assert _skySetup is not Undefined, "SkySetup must be provided in the extra resources"

_provCfg = _extraRes["ProviderConfigs"]?[0]
assert _provCfg is not Undefined, "ProviderConfig must be provided in the extra resources"

_initScripts = _extraRes["InitScripts"]
assert _initScripts is not Undefined, "Init scripts must be provided in the extra resources"

_initScriptsSSH = _extraRes["InitScriptsSSH"]
assert _initScriptsSSH is not Undefined, "Init scripts SSH must be provided in the extra resources"

_oxrName = oxr.metadata.name
_oxrProvRegion = oxr.spec.providerRef.region
_oxrProvZone = oxr.spec.providerRef.zones.primary
_oxrProvPlatform = oxr.spec.providerRef.platform
_oxrAppId = oxr.spec.applicationId or Undefined
_oxrAnnotations = oxr.metadata.annotations

assert _oxrProvRegion and _oxrProvZone and _oxrProvPlatform, \
  "Provider region, primary zone, platform must be specified"

_skyK8SProviderCfgName = _skySetup.status?.providerConfig?.kubernetes?.name

_defaults = {
  providerConfigRef = {
    name = _provCfg.metadata.name
  },
}

_default_labels = {
  **oxr.metadata?.labels,
  **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _oxrAppId),
}

_default_annotations = {
  **oxr.metadata?.annotations,
  **helper._is_paused_label(oxr.metadata.labels),
}

_filter_objects: (any, str) -> [any] = lambda _objects, role {
  [{
    name = o.metadata?.name
    object = o
  } for o in _objects if o and o.metadata?.labels["skycluster.io/instance-role"] == role]
}

_select_scripts: (any, [str]) -> any = lambda _scripts, names {
  _selected = [s.data for s in _scripts for n in names if s and n.lower() == s.metadata?.labels["skycluster.io/script-init"]]
  assert len(_selected) == 1, "Expected exactly one script, found {}".format(len(_selected))
  _selected[0]
}

_merge = lambda map1, map2 {map1 | map2}
_replace: (str, str, str, str) -> str = lambda s:str, p:str, r:str, z:str {
  s.replace("__PROVIDERPLATFORM__", p)\
    .replace("__REGION__", r)\
      .replace("__ZONE__", z)
}
_replace_with: (str, str, str) -> str = lambda s:str, k:str, v:str {
  s.replace(k, v)
}

_ns = "skycluster-system"
_ud = oxr.spec?.userData or Undefined
_scripts = ["k3s-controller"]
_defaultUserData = yaml.decode(helper._select_init_scripts(_initScripts, _scripts)) or Undefined
_userDataCtrl = helper._append_init_scripts([_defaultUserData] + ([yaml.decode(_ud)] if _ud else []))

# This is cloud-init
_userDataCtrl = _replace(
  _userDataCtrl, _oxrProvPlatform, _oxrProvRegion, _oxrProvZone
) if _userDataCtrl else Undefined

# This is config map
_k3sCtrlScript = _select_scripts(_initScriptsSSH, ["k3s-controller-check"]) or {}
_k3sAgentScript: {str:str} = _select_scripts(_initScriptsSSH, ["k3s-agent"]) or {}

_agentProbeScript = _replace(
  _k3sAgentScript["probeScript"], _oxrProvPlatform, _oxrProvRegion, _oxrProvZone
) if _k3sAgentScript else Undefined
_agentEnsureScript = _replace(
  _k3sAgentScript["ensureScript"], _oxrProvPlatform, _oxrProvRegion, _oxrProvZone
) if _k3sAgentScript else Undefined


_items = []


# <hash> = ng
_ctrlNodeGroup = {
  crypto.md5( "{}{}{}".format(ng.role, ng.instanceType, ng.publicAccess)) = ng \
    for ng in oxr.spec.nodeGroups if ng and ng.role == "control-plane"
}
_maxNodeCount = 1
assert len(_ctrlNodeGroup) == 1, "Exactly one control-plane node group is supported, found {}".format(len(_ctrlNodeGroup))

# Ensure only one node group and only one node is defined as controller
# We may expand this in future release to support mult-controller Kubernetes
_ctrlNode = [nc for _, nc in _ctrlNodeGroup]?[0] or Undefined
_ctrlPublicAccess = _ctrlNode?.publicAccess or False
_ctrlNodeCount = _ctrlNode?.nodeCount
assert _ctrlNodeCount == 1, "Only support one controller node per group in this version, found {}".format(len(_ctrlNodeGroup))
assert _ctrlPublicAccess, "Control plane node must be publicly accessible, found publicAccess: {}".format(_ctrlPublicAccess)

# ct<hash>I<id> = ctrlObjData
_ctrlObjDataBase = {
  "ct{}I{}".format(k, j): {
    nodeGroupHash = k
    id = str(j)
    role = ng.role,
    instanceType = ng.instanceType,
    publicAccess =  ng.publicAccess
  } for k, ng in _ctrlNodeGroup for j in range(0, min(_maxNodeCount, ng.nodeCount))
}

# Add additional map str:str
_ctrlObjData = {
  k = _merge(
    v,
    {
      controller = { # xinstance
        generate = k
        observed = ocds?[k]?.Resource?.metadata?.name
      }
      ssh = { # sshtask: install k3s
        generate = "st{}I{}".format(v.nodeGroupHash, v.id)
        observed = ocds?[generate]?.Resource?.metadata?.name
      }
      secret = { # secret (object) containing kubeconfig
        generate = "sc{}I{}".format(v.nodeGroupHash, v.id)
        observed = ocds?[generate]?.Resource?.status?.atProvider?.manifest?.metadata?.name
      }
      providerConfigs = { # provider config for ctrl xinstance
        k8s = { # k3s provider config
          generate = "pc{}I{}".format(v.nodeGroupHash, v.id)
          observed = ocds?[generate]?.Resource?.metadata?.name
        }
        ssh = { # providerconfig for ssh (comes from XInstance)
          observed = ocds?[k]?.Resource?.status?.providerConfig?.kubernetes?.name
        }  
      }

      # Comes from sshtask
      token = ocds?[ssh?.generate]?.Resource?.status?.atProvider?.observed?.fields?.token
      kubeconfig_encoded = ocds?[ssh?.generate]?.Resource?.status?.atProvider?.observed?.fields?.kubeconfig

      # Comes from xinstance
      privateIp = ocds?[k]?.Resource?.status?.network?.privateIp
      publicIp = ocds?[k]?.Resource?.status?.network?.publicIp
      
      sshGate = all_true([
        _agentProbeScript, 
        _agentEnsureScript, 
        providerConfigs?.ssh?.observed # defined above
      ])
      secretGate = all_true([
        ocds?[ssh?.generate]?.Resource?.status?.atProvider?.observed?.fields?.token,
        ocds?[ssh?.generate]?.Resource?.status?.atProvider?.observed?.fields?.kubeconfig,
        ocds?[k]?.Resource?.status?.network?.privateIp
      ])
      providerCfgGate = all_true([
        len(ocds?[secret?.generate]?.Resource?.status?.atProvider?.manifest?.data or []) > 0,
      ])
    }
  ) for k, v in _ctrlObjDataBase
}


# ctrl xinstance(s)
# Multi controller is not yet supported, we capture the first nodegroup 
# specified for control-plane and create an instance for it (ignoring nodeCount)
_items += [
  {
    "apiVersion" = "skycluster.io/v1alpha1",
    "kind" = "XInstance",
    "metadata" = {
      labels = _default_labels | {
        "skycluster.io/instance-role" = "controller"
      }
      annotations = _default_annotations | {
        # We fetch the first nodeGroup, and we hash the nodeGroup, so if the first nodeGroup
        # changed, the resource is re-created subsequently
        **helper._set_resource_name(k),
      },
    },
    "spec" = {
      "applicationId" = _oxrAppId,
      "ipForwarding" = True,
      "image" = "ubuntu-24.04",
      "flavor" = c.instanceType,
      "publicIp" = True, # controller need to be accessible
      "providerRef" = {
        "platform" = _oxrProvPlatform,
        "region" = _oxrProvRegion,
        "zone" = _oxrProvZone
      },
      "userData" = _userDataCtrl
    }
  } for k, c in _ctrlObjData 
]


# Controller ssh connection sshtask, it install k3s
# Multi controller is not yet supported
_items += [
  {
    apiVersion = "ssh.crossplane.io/v1alpha1"
    kind = "SSHTask"
    metadata = {
      labels = _default_labels
      annotations = _default_annotations | {
        **helper._set_resource_name(cv.ssh?.generate),
      },
    },
    spec = {
      providerConfigRef.name = cv.providerConfigs?.ssh?.observed
      forProvider = {
        scripts = {
          probeScript.inline = _k3sCtrlScript?["probeScript"]
          ensureScript.inline = _k3sCtrlScript?["ensureScript"]
        }
        observe = {
          refreshPolicy = "Always"
          capture = "both"
          "map" = [{
              from = "network.ip"
              to = "ip"
            }, {
              from = "kubeconfig.token"
              to = "token"
            }, {
              from = "kubeconfig.encoded"
              to = "kubeconfig"
            }
          ]
        }
        execution = {
          sudo = True
          shell = "/bin/bash -euo pipefail"
          timeoutSeconds = 600
          maxAttempts = 30
        }
        artifactPolicy.capture = "both"    
      }
    }
  } for c, cv in _ctrlObjData if cv.sshGate or ocds?[cv.ssh?.generate]
]


# Controller ssh connection secret, it saves a secret containing k3s token and kubeconfig
# Multi controller is not yet supported
_items += [
  k8sv1a2.Object{
    metadata = {
      labels = _default_labels
      annotations = _default_annotations | {
        # We fetch the first nodeGroup, and we hash the nodeGroup, so if the first nodeGroup
        # changed, the resource is re-created subsequently
        **helper._set_resource_name(cv.secret?.generate),
      },
    },
    spec = {
      forProvider = {
        manifest = {
          apiVersion = "v1",
          kind = "Secret",
          metadata = {
            name = "k3s-{}-{}-{}".format(_oxrProvPlatform.lower(), _oxrProvRegion.lower(), cv.privateIp),
            namespace = _ns,
            labels = _default_labels | {
              "skycluster.io/secret-type" = "k8s-connection-data",
            },
            annotations = _default_annotations,
          },
          "type" = "Opaque",
          data = {
            "kubeconfig" = cv.kubeconfig_encoded,
            "token" = base64.encode(cv.token)
          }
        },
      },
      providerConfigRef.name = _skyK8SProviderCfgName
    }
  } for c, cv in _ctrlObjData if cv.secretGate or ocds?[cv.secret?.generate]
]

# Controller Kubernetes provider config connection 
# Multi controller is not yet supported
_items += [
  k8sv1a1.ProviderConfig{
    metadata = {
      labels = _default_labels
      annotations = _default_annotations | {
        **helper._set_resource_name(cv.providerConfigs?.k8s?.generate),
        "krm.kcl.dev/ready" = "True"
      },
    },
    spec = {
      credentials = {
        source = "Secret"
        secretRef = {
          namespace = _ns
          name = cv?.secret?.observed
          key = "kubeconfig"
        }
      }
    }
  } for c, cv in _ctrlObjData if cv.providerCfgGate or ocds?[cv.providerConfigs?.k8s?.generate]
]



# ###################### Note ######################

# There may be multiple controller, however, we only support single controller
# This means we use one IP and Token corresponding to one controller, even 
# if user has specified multiple node groups for controller with node count > 1

# In the output (status) fieds, we offer all controllers information.

# ###################### Agents ######################

_ctrlIp = [v.privateIp for _, v in _ctrlObjData][0]
_ctrlIpPublic = [v.publicIp for _, v in _ctrlObjData][0]
_ctrlToken = [v.token for _, v in _ctrlObjData][0]
_ctrlKubeconfig_enc = [v.kubeconfig_encoded for _, v in _ctrlObjData][0]


_agNodeGroup = {
  crypto.md5( "{}{}{}".format(ng.role, ng.instanceType, ng.publicAccess)) = ng \
    for ng in oxr.spec.nodeGroups if ng and ng.role == "worker"
}

# ct<hash>I<id> = ctrlObjData
_agObjDataBase = {
  "ag{}I{}".format(k, j): {
    nodeGroupHash = k
    id = str(j)
    role = ng.role,
    instanceType = ng.instanceType,
    publicAccess =  ng.publicAccess
  } for k, ng in _agNodeGroup for j in range(0, ng.nodeCount)
}


# Add additional map str:str
_agentObjData = {
  k = _merge(
    v, 
    {
      agent = { # xInstance: agent joining controller
        generate = k
        observed = ocds?[k]?.Resource?.metadata?.name
      }
      providerConfigs = { # provider configs for agent node
        ssh = { # sshtask provider
          observed = ocds?[k]?.Resource?.status?.providerConfig?.kubernetes?.name
        }
      }
      ssh = { # sshtask: joining k3s
        generate = "st{}I{}".format(v.nodeGroupHash, v.id)
        observed = ocds?[generate]?.Resource?.metadata?.name
      }
      
      sshGate = all_true([
        _ctrlToken,
        _ctrlIp,
        ocds?[k]?.Resource?.status?.providerConfig?.kubernetes?.name,
        ocds?[k]?.Resource?.status?.network?.privateIp
      ])

      # k refers to agent (xInstance)
      privateIp = ocds?[k]?.Resource?.status?.network?.privateIp
      publicIp = ocds?[k]?.Resource?.status?.network?.publicIp
    }
  ) for k, v in _agObjDataBase
}

#
# Agent xInstance(s)
#
_items += [
  {
    "apiVersion" = "skycluster.io/v1alpha1",
    "kind" = "XInstance",
    "metadata" = {
      labels = _default_labels | {
        "skycluster.io/instance-role" = "worker"
      }
      annotations = _default_annotations | {
        **helper._set_resource_name(k),
      },
    },
    "spec" = {
      "applicationId" = _oxrAppId,
      "ipForwarding" = True,
      "image" = "ubuntu-24.04",
      "flavor" = v.instanceType,
      "publicIp" = v.publicAccess,
      "providerRef" = {
        "platform" = _oxrProvPlatform,
        "region" = _oxrProvRegion,
        "zone" = _oxrProvZone
      },
    }
  } for k, v in _agentObjData if v or ocds?[k]
]


# agent ssh connection sshtask
_items += [
  {
    apiVersion = "ssh.crossplane.io/v1alpha1"
    kind = "SSHTask"
    metadata = {
      labels = _default_labels
      annotations = _default_annotations | {
        **helper._set_resource_name(v.ssh?.generate),
      },
    },
    spec = {
      providerConfigRef.name = v.providerConfigs?.ssh?.observed
      forProvider = {
        scripts = {
          # TODO: change with agent script
          probeScript.inline = _agentProbeScript
          ensureScript.inline = _agentEnsureScript
        }
        observe = {
          refreshPolicy = "Always"
          # TODO: change with agent script
          capture = "both"
          "map" = [{
              from = "k3s.version"
              to = "k3sVersion"
            }, {
              from = "k3s.agentActive"
              to = "agentActive"
            }, {
              from = "k3s.screenExists"
              to = "screenExists"
            }
          ]
        }
        execution = {
          sudo = True
          shell = "/bin/bash -euo pipefail"
          timeoutSeconds = 600
          maxAttempts = 30
          env = [
            {
              name = "__K3STOKEN__",
              value = _ctrlToken,
            },
            {
              name = "__K3SHOSTIP__",
              value = _ctrlIp
            }
          ]
        }
        artifactPolicy.capture = "both"    
      }
    }
  } for k, v in _agentObjData if v.sshGate or ocds?[v.ssh?.generate]
] 



# ###################### dxr ######################

dxr = {
  **option("params").dxr,
  status = {
    controllers = [
      {
        k = v for id, obj in _ctrlObjData for k, v in obj if k not in ["token", "kubeconfig_encoded"]
      }
    ]
    agents = [
      {
        k = v for id, obj in _agentObjData for k, v in obj
      } 
    ]
    # log = json.encode({
    #   ctrlObject = _ctrlObjData
    #   agObject = _agentObjData
    # })
  }
}

items = [*_items, dxr]