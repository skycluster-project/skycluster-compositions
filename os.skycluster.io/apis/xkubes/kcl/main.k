
import yaml
import helper.v1alpha1.main as helper
import provider_openstack.v1alpha1 as opv1a1
import provider_helm.v1beta1 as helmv1b1
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

_xSetup = _extraRes["XSetup"][0]
assert _xSetup is not Undefined, "XSetup must be provided in the extra resources"

_initScripts = _extraRes["InitScripts"]
assert _initScripts is not Undefined, "Init scripts must be provided in the extra resources"

_oxrName = oxr.metadata.name
_oxrProvRegion = oxr.spec.providerRef.region
_oxrProvZone = oxr.spec.providerRef.zones.primary
_oxrProvPlatform = oxr.spec.providerRef.platform
_oxrAppId = oxr.spec.applicationId or Undefined
_oxrAnnotations = oxr.metadata.annotations

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

assert _oxrProvRegion and _oxrProvZone and _oxrProvPlatform, \
  "Provider region, primary zone, platform must be specified"

_ns = "skycluster-system"
_ud = oxr.spec?.userData or Undefined
_scripts = ["k3s-controller"]
_defaultUserData: any = yaml.decode(helper._select_init_scripts(_initScripts, _scripts)) or Undefined
_userDataCtrl = helper._append_init_scripts([_defaultUserData] + [yaml.decode(_ud)] if _ud else [])

_userDataCtrl = _userDataCtrl.replace("__PROVIDERPLATFORM__", _oxrProvPlatform)
_userDataCtrl = _userDataCtrl.replace("__REGION__", _oxrProvRegion)
_userDataCtrl = _userDataCtrl.replace("__ZONE__", _oxrProvZone)

_items = []

_controllerNodes = [n for n in oxr.spec.nodeGroups if n and n.role == "control-plane" ]
_items += [
  {
    "apiVersion": "os.skycluster.io/v1alpha1",
    "kind": "XInstance",
    "metadata": {
      labels = _default_labels
      annotations = _default_annotations | {
        **helper._set_resource_name("ctrl{}".format(i)),
      },
    },
    "spec": {
      "applicationId": _oxrAppId,
      "ipForwarding": True,
      "image": "ubuntu-24.04",
      "flavor": n.instanceType,
      "publicIp": True,
      "providerRef" = {
        "platform" = _oxrProvPlatform,
        "region" = _oxrProvRegion,
        "zone" = _oxrProvZone
      },
      "userData": _userDataCtrl
    }
  } for i, n in _controllerNodes
] if _controllerNodes else []



dxr = {
  **option("params").dxr,
  # status.network = {
  #   privateIp = _privateAddress
  #   publicIp = _publicAddress
  # } if _privateAddress or _publicAddress else Undefined,
}

items = [*_items, dxr]