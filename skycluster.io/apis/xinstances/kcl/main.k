import yaml
import helper.v1alpha1.main as helper

oxr = option("params").oxr # observed composite resource
ocds = option("params")?.ocds # observed composed resources
# _dxr = option("params").dxr # desired composite resource
# dcds = option("params").dcds # desired composed resources

ctx = option("params")?.ctx
assert ctx is not Undefined, "Context must be provided in the params"

_extraRes = ctx["apiextensions.crossplane.io/extra-resources"]
assert _extraRes is not Undefined, "Extra resources must be provided in the context"

_provSettings = _extraRes["ProviderSettings"]?[0] 
assert _provSettings is not Undefined, "Provider settings must be provided in the extra resources"

_skySetup = _extraRes["SkySetups"][0]
assert _skySetup is not Undefined, "SkySetup must be provided in the extra resources"

_initScripts = _extraRes["InitScripts"]
assert _initScripts is not Undefined, "Init scripts must be provided in the extra resources"

_oxrProvPlatform = oxr.spec?.providerRef?.platform or Undefined
_oxrProvRegion = oxr.spec?.providerRef?.region or Undefined
_oxrProvZone = oxr.spec?.providerRef?.zone or Undefined
_appId = oxr.spec?.applicationId or Undefined
assert _oxrProvPlatform and _oxrProvRegion and _oxrProvZone and _appId, \
  "Provider platform, region, and primary zone and application ID must be specified in the providerRef"


_publicKey = oxr.spec?.publicKey or _skySetup.status?.keypair?.publicKey
assert _publicKey, "Public key must be specified in the SkySetup status"

_ami = helper._get_image(_provSettings, oxr.spec?.image or "ubuntu-24.04", _oxrProvZone)?.name
_it = helper._get_instance_type(_provSettings, oxr.spec?.flavor or "2vCPU-4GB", _oxrProvZone)?[0]

_ud = oxr.spec?.userData or Undefined
_scripts = ["routing-gateway", "ip-forwarding"]
_defaultUserData: any = yaml.decode(helper._select_init_scripts(_initScripts, _scripts)) or Undefined
_userData = helper._append_init_scripts([_defaultUserData] + [yaml.decode(_ud)] if _ud else [])

_items = [
  {
    apiVersion = "aws.skycluster.io/v1alpha1"
    kind = "XInstance"
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _appId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("xinstance")
      }
    }
    spec = {
      applicationId = _appId
      flavor = _it
      image = _ami
      publicKey = _publicKey
      publicIp = oxr.spec?.publicIp or False
      userData = _userData
      securityGroups = oxr.spec?.securityGroups
      rootVolumes = oxr.spec?.rootVolumes or [
        {
          size = "20"
          type = "gp2" # TODO: does gpt2 work for all providers?
        }
      ]
      providerRef={
        platform= _oxrProvPlatform
        region= _oxrProvRegion
        zone = _oxrProvZone
      }
    }
  }
] if oxr.spec?.providerRef?.platform == "aws" else []

_items = [
  {
    apiVersion = "gcp.skycluster.io/v1alpha1"
    kind = "XInstance"
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, _appId),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("xinstance")
      }
    }
    spec = {
      applicationId = _appId
      flavor = _it
      image = _ami
      publicKey = _publicKey
      publicIp = oxr.spec?.publicIp or False
      userData = _userData
      securityGroups = oxr.spec?.securityGroups
      rootVolumes = oxr.spec?.rootVolumes or [
        {
          size = "20"
          type = "pd-standard" 
        }
      ]
      providerRef={
        platform= _oxrProvPlatform
        region= _oxrProvRegion
        zone = _oxrProvZone
      }
    }
  }
] if oxr.spec?.providerRef?.platform == "gcp" else []


_publicIp = ocds?["xinstance"]?.Resource?.status?.network?.publicIp or Undefined
_privateIp = ocds?["xinstance"]?.Resource?.status?.network?.privateIp or Undefined

dxr = [{
  **option("params").dxr,
  # status.log = _userData
  status.network = {
    privateIp = _privateIp
    publicIp = _publicIp
  } if _privateIp or _publicIp else Undefined,
}]

items = _items + dxr