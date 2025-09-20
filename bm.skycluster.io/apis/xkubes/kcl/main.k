import yaml
import json
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
assert _initScriptsSSH is not Undefined, "Init scripts SSH must be provided in the extra resources"

_cms = _extraRes["ConfigMaps"][0]

_skySetup = _extraRes["SkySetups"][0]
assert _skySetup, "SkySetup resource must be provided in the extra resources"

_xSetup = _extraRes["XSetup"][0]
assert _xSetup, "XSetup resource must be provided in the extra resources"

_subnetCidr = _xSetup.status?.subnetCidr or Undefined
assert _subnetCidr, "Subnet CIDR must be specified in the XSetup status"

_k8sProvCfgName = _skySetup.status?.providerConfig?.kubernetes?.name or Undefined

_caCertificateB64 = _skySetup.status?.ca.certificate or Undefined
assert _k8sProvCfgName and _caCertificateB64, \
  "Kubernetes provider config name and CA certificate must be specified in the SkySetup status"

_loginUrl = _skySetup.status?.headscale?.loginUrl 
assert _loginUrl, "Headscale login URL must be specified in the SkySetup status"

_hsToken = _skySetup.status?.headscale?.token
assert _hsToken, "Headscale token must be specified in the SkySetup status"

assert _oxrProvRegion and _oxrProvZone and _oxrProvPlatform, \
  "Provider region, primary zone, platform must be specified"

_select_scripts: (any, [str]) -> any = lambda _scripts, names {
  _selected = [s.data \
    for s in _scripts \
      for n in names if s and n.lower() == s.metadata?.labels["skycluster.io/script-init"]
  ]
  assert len(_selected) == 1, "Expected exactly one script, found {}".format(len(_selected))
  _selected[0]
}

_K3sControllerScript = _select_scripts(_initScriptsSSH, ["bm-k3s-controller"])
_K3sAgentScript = _select_scripts(_initScriptsSSH, ["k3s-agent"])
assert _K3sControllerScript and _K3sAgentScript, "K3s controller and agent scripts must be provided in the context"

_k3sCtrlProbSc = _K3sControllerScript?.data?["k3s_controller_prob.sh"] or Undefined  
_k3sCtrlEnsureSc = _K3sControllerScript?.data?["k3s_controller.sh"] or Undefined
assert _k3sCtrlProbSc and _k3sCtrlEnsureSc, "K3s controller scripts must be provided in the context"

_k3sAgentProbSc = _K3sAgentScript?.data?["probeScript.sh"] or Undefined
_k3sAgentEnsureSc = _K3sAgentScript?.data?["ensureScript.sh"] or Undefined
assert _k3sAgentProbSc and _k3sAgentEnsureSc, "K3s agent scripts must be provided in the context"


assert oxr.spec?.gatewayDeviceName, "Gateway device name must be specified"

_gatewayNodeStr = _cms.data?["gateway"] or Undefined
_workerNodesStr = _cms.data?["worker"] or Undefined

_gwNodes = yaml.decode(_gatewayNodeStr) if _gatewayNodeStr else Undefined
_workerNodes = yaml.decode(_workerNodesStr) if _workerNodesStr else []

#
# Only supporting one gateway node for now
#
_gwNodeName = oxr.spec?.gatewayDeviceName
assert _gwNodeName, "Gateway device name must be specified"
assert _gwNodeName in _gwNodes, "Gateway device name '{}' not found in the configmap".format(_gwNodeName)

_workerNodeNames = oxr.spec?.workerDeviceNames or []
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
    sshProviderCfgName = _provisionedGwNodes[n]?.sshProviderCfgName
    sshSecretName = _provisionedGwNodes[n]?.sshSecretName
  } for n in [_gwNodeName] \
      if _gwNodes and n in _gwNodes and n in _provisionedGwNodes
}

#
# Worker nodes Map
#
_workerNodesMap: {str:any} = {
  n = {
    **_workerNodes[n],
    sshProviderCfgName = _provisionedWorkerNodes[n]?.sshProviderCfgName,
    sshSecretName = _provisionedWorkerNodes[n]?.sshSecretName,
  } for n in _workerNodeNames \
      if _workerNodes and n in _workerNodes and n in _provisionedWorkerNodes
}


# Depends on K3S controller installation
# _k3sAgentEnsureSc = _k3sAgentEnsureSc.replace("__K3STOKEN__", _k3sToken)\
#   .replace("__K3SHOSTIP__", _k3sHostIP)\
#   .replace("__PROVIDERPLATFORM__", _oxrProvPlatform)\
#   .replace("__REGION__", _oxrProvRegion)\
#   .replace("__ZONE__", _oxrProvZone)


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
  _helper_ssh_task(
      "k3s-ctrl-{}".format(n),
      spec.sshProviderCfgName,
      spec.sshSecretName,
      _k3sCtrlProbSc, _k3sCtrlEnsureSc) \
    for n, spec in _gwNodesMap \
      if spec.sshProviderCfgName and spec.sshSecretName or ocds?["k3s-ctrl-{}".format(n)]
] 

_k3sData = ocds?["k3s-ctrl-{}".format(n)]?.Resource.status?.observed.fields or Undefined

# extraItems = {
#   apiVersion = "meta.krm.kcl.dev/v1alpha1"
#   kind = "ExtraResources"
#   requirements = {
#     **{"bmPrivateKeySecrets" = {
#         apiVersion: "v1",
#         kind: "Secret",
#         # we cannot use matchName because the secret is namespaced
#         # hence we filter by label instead and check the name later
#         matchLabels = {
#           "skycluster.io/managed-by" = "skycluster",
#           "skycluster.io/secret-type" = "onpremise-keypair"
#         }
#     }}
#   }
# }

dxr = {
  **option("params").dxr,
  status = {
    log = json.encode(_k3sData)
    # subnetCidr = _subnetCidr,
    # gateway = {
    #   publicIp = _gwNodesMap?[_gwNodeName]?.publicIp,
    #   privateIp = _gwNodesMap?[_gwNodeName]?.privateIp,
    #   username = _gwNodesMap?[_gwNodeName]?.auth?.username,
    # }
    # auth = {
    #   secretName = _gwPrivateKeySecretName or Undefined
    #   # privateKey = _defaultPrivateKey or Undefined
    # } if _defaultPrivateKey else Undefined
  }
}

# Collect all resources into a list for output
items = [*_items, dxr]


# Helper to install and setup tailscale
_helper_ssh_task = lambda s, pvCfgName, pbScript, ensScript {
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
          "map" = []
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