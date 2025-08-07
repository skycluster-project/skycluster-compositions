import helper.v1alpha1.main as helper
import helper.v1alpha1.aws as helper_aws

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

_oxrProvPlatform = oxr.spec?.providerRef?.platform or Undefined
_oxrProvRegion = oxr.spec?.providerRef?.region or Undefined
_oxrProvZones = oxr.spec?.providerRef?.zones or Undefined
_oxrProvZone = oxr.spec?.providerRef?.zones?.primary or Undefined

assert _oxrProvPlatform and _oxrProvRegion and _oxrProvZone, \
  "Provider platform, region, and primary zone and must be specified in the providerRef"

_svcCidr = oxr.spec?.serviceCidr or Undefined
_nodesTypes = oxr.spec?.nodeTypes or Undefined
_principal = oxr.spec?.principal or Undefined



_nodeTypes = [
  helper_aws._get_instance_type_aws(_provSettings, _it or "2vCPU-4GB", _oxrProvZone) for _it in _nodesTypes
] if _nodesTypes else ["t3.medium"]

_items = []

_items += [
  {
    apiVersion = "aws.skycluster.io/v1alpha1"
    kind = "XKube"
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        **helper._set_default_labels(_oxrProvPlatform, _oxrProvRegion, _oxrProvZone, ""),
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("xk8s")
      }
    }
    spec = {
      applicationId = oxr.spec?.applicationId or Undefined
      serviceCidr = oxr.spec?.serviceCidr or Undefined
      principalArn = oxr.spec?.principal?.id or Undefined
      nodeGroups = [
        {
          nodeCount = 1
          instanceTypes = _nodeTypes
          publicAccess = True
          autoScaling = {
            enabled = True
            minSize = 1
            maxSize = 1
          }
        },
        {
          nodeCount = 1
          instanceTypes = _nodesTypes 
          publicAccess = False
          autoScaling = {
            enabled = True
            minSize = 1
            maxSize = 3
          }
        } if _nodesTypes else {}
      ]
      providerRef = {
        platform = _oxrProvPlatform
        region = _oxrProvRegion
        zones = _oxrProvZones
      }
    }
  } if _oxrProvPlatform == "aws" else Undefined
] if oxr.spec?.providerRef?.platform == "aws" else []


items = _items