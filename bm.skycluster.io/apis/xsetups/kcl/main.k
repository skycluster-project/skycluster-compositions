import yaml
import json
import base64
import helper.v1alpha1.main as helper
import provider_kubernetes.v1alpha2 as k8sv1a2

oxr = option("params").oxr # observed composite resource
ocds = option("params")?.ocds # observed composed resources
extra = option("params")?.extraResources
# _dxr = option("params").dxr # desired composite resource
# dcds = option("params").dcds # desired composed resources

assert oxr.metadata?.labels is not Undefined, "At least one label must be specified"
assert "skycluster.io/managed-by" in oxr.metadata.labels, "Label 'skycluster.io/managed-by' must be specified"

ctx = option("params")?.ctx
assert ctx is not Undefined, "Context must be provided in the params"

_extraRes = ctx["apiextensions.crossplane.io/extra-resources"]
assert _extraRes is not Undefined, "Extra resources must be provided in the context"

_cms = _extraRes["ConfigMaps"][0]
_skySetup = _extraRes["SkySetups"][0]

_ns = _skySetup.spec.namespace or "skycluster-system"

_oxrProvRegion = oxr.spec.providerRef.region
_oxrProvZone = oxr.spec.providerRef.zones?.primary
_oxrProvPlatform = oxr.spec.providerRef.platform
_oxrAppId = oxr.spec.applicationId or Undefined

assert _oxrProvRegion and _oxrProvZone and _oxrProvPlatform, "Provider region, primary zone, platform must be specified"

assert oxr.spec?.gatewayDeviceName, "Gateway device name must be specified"

_gatewayNodeStr = _cms.data?["gateway"] or Undefined
_workerNodesStr = _cms.data?["worker"] or Undefined

_gwNode = yaml.decode(_gatewayNodeStr) if _gatewayNodeStr else Undefined
_gwWorkers = yaml.decode(_workerNodesStr) if _workerNodesStr else []

# Only supporting one gateway node for now
_gwNodeName = oxr.spec?.gatewayDeviceName
_wrokerNodeNames = oxr.spec?.workerDeviceNames or []

# Fetch node spec
_gwNodeSpec = _gwNode[_gwNodeName] if _gwNode and _gwNodeName and _gwNodeName in _gwNode else Undefined
_workerNodeSpecs = [_gwWorkers[n] for n in _wrokerNodeNames if _gwWorkers and n in _gwWorkers] if _wrokerNodeNames else []


_subnetCidr = _gwNodeSpec?.privateIp
_subnetCidrOctets = _subnetCidr.split(".")
_subnetCidrFirst = _subnetCidrOctets[0]
_subnetCidrSecond = _subnetCidrOctets[1]
_subnetCidrThird = _subnetCidrOctets[2]
_subnetCidr = "{}.{}.{}.0/24".format(_subnetCidrFirst, _subnetCidrSecond, _subnetCidrThird)


# Retrieve secret containing the private key for gateway and workers
_gwPrivateSecretName = _gwNodeSpec?.auth?.privateKeySecretRef?.name
_gwPrivateSecretKey = _gwNodeSpec?.auth?.privateKeySecretRef?.key
# Encrypted private key:

_gwSecrets = extra?["bmPrivateKeySecrets"]
_gwSecretData = [_sec.Resource.data for _sec in _gwSecrets if _sec.Resource.metadata?.name == _gwPrivateSecretName] if _gwSecrets and _gwPrivateSecretName else []

_gwPrivateKeyB64 = _gwSecretData?[0]?[_gwPrivateSecretKey] or Undefined
# Decrypted private key
_defaultPrivateKey = base64.decode(_gwPrivateKeyB64) if _gwPrivateKeyB64 else Undefined

_items = []


extraItems = {
  apiVersion = "meta.krm.kcl.dev/v1alpha1"
  kind = "ExtraResources"
  requirements = {
    **{"bmPrivateKeySecrets" = {
        apiVersion: "v1",
        kind: "Secret",
        # we cannot use matchName because the secret is namespaced
        # hence we filter by label instead and check the name later
        matchLabels = {
          "skycluster.io/managed-by" = "skycluster",
          "skycluster.io/secret-type" = "onpremise-keypair"
        }
    }}
  }
}

dxr = {
  **option("params").dxr,
  status = {
    # log = json.encode(extra)
    subnetCidr = _subnetCidr,
    gateway = {
      publicIp = _gwNodeSpec?.publicIp,
      privateIp = _gwNodeSpec?.privateIp,
      username = _gwNodeSpec?.auth?.username,
    }
    auth = {
      secretName = _gwPrivateSecretName or Undefined
      # privateKey = _defaultPrivateKey or Undefined
    } if _defaultPrivateKey else Undefined
  }
}

# Collect all resources into a list for output
items = [*_items, dxr, extraItems]

# _secretSSHGate = all_true([_privateIp, _defaultPrivateKey, _providerK8SCfgName])
# _items += [k8sv1a2.Object{
#   "metadata": {
#     labels = _default_labels
#     annotations = _default_annotations | {
#       **helper._set_resource_name("secRemoteSSH"),
#     },
#   },
#   spec = {
#     forProvider = {
#       manifest = {
#         apiVersion: "v1",
#         kind: "Secret",
#         metadata: {
#           name: "ssh-{}-{}-{}".format(_oxrProvPlatform.lower(), _oxrProvRegion.lower(), _privateIp),
#           namespace: _ns,
#           labels: _default_labels,
#           annotations: _default_annotations,
#         },
#         type = "Opaque",
#         stringData = {
#           config = json.encode({
#             username = "ubuntu"
#             password = ""
#             hostIP = _privateIp
#             hostPort = "22"
#             privateKey = base64.encode(_defaultPrivateKey)
#           })
#         }
#       },
#     }
#     providerConfigRef.name = _providerK8SCfgName
#   }
# }] if _secretSSHGate or ocds?["sshSecret"] else []

# _sshSecretName = ocds?["secRemoteSSH"]?.Resource?.status?.atProvider?.manifest?.metadata?.name
# _provCfgGate = all_true([_sshSecretName, _providerK8SCfgName])
# _items += [k8sv1a2.Object{
#   "metadata" = {
#     labels = _default_labels
#     annotations = _default_annotations | {
#       **helper._set_resource_name("sshProviderConfig"),
#     },
#   },
#   spec = {
#     references = [{
#       # TODO: When object is deleted, the providerconfig remains
#       # Manual deletion of provider config does not remove the finalizer on the secret
#       # The owner of secret still remains waiting for secret to be removed.
#       dependsOn = {
#         apiVersion = "v1"
#         kind = "Secret"
#         name = "ssh-{}-{}-{}".format(_oxrProvPlatform.lower(), _oxrProvRegion.lower(), _privateIp),
#         namespace = _ns
#       }
#     }]
#     deletionPolicy = "Delete"
#     forProvider = {
#       manifest = {
#         apiVersion = "ssh.crossplane.io/v1alpha1",
#         kind = "ProviderConfig",
#         metadata = {
#           name = "ssh-{}-{}-{}".format(_oxrProvPlatform.lower(), _oxrProvRegion.lower(), _privateIp),
#           namespace = _ns,
#           labels = _default_labels,
#           annotations = _default_annotations,
#         },
#         spec = {
#           credentials = {
#             source = "Secret"
#             secretRef = {
#               name = _sshSecretName
#               namespace = _ns,
#               key = "config"
#             }
#           }
#         }
#       },
#     },
#     providerConfigRef.name = _providerK8SCfgName
#   }
# }] if _provCfgGate or ocds?["sshProviderConfig"] else []
