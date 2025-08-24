import json
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

_oxrProvPlatform = oxr.spec?.providerRef?.platform or Undefined
_oxrProvRegion = oxr.spec?.providerRef?.region or Undefined
_oxrProvZones = oxr.spec?.providerRef?.zones or Undefined
_oxrProvZone = oxr.spec?.providerRef?.zones?.primary or Undefined

_ami = helper._get_image(_provSettings, oxr.spec?.image or "ubuntu-24.04", _oxrProvZone)?.name
_it = helper._get_instance_type(_provSettings, oxr.spec?.flavor or "2vCPU-4GB", _oxrProvZone)?[0]

assert _oxrProvPlatform and _oxrProvRegion and _oxrProvZone, \
  "Provider platform, region, and primary zone and must be specified in the providerRef"

# If it is OpenStack or baremetal, then the control plane must be provided.
assert oxr.spec?.controlPlane or _oxrProvPlatform.lower() in ["aws", "gcp", "azure"], \
  "Control plane is required for unmanaged clusters (e.g. OpenStack)"

_svcCidr = oxr.spec?.serviceCidr or Undefined
_nodesTypes = oxr.spec?.nodeTypes or Undefined
_principal = oxr.spec?.principal or Undefined


_a = [helper._get_instance_type(_provSettings, _it or "2vCPU-4GB", _oxrProvZone) for _it in _nodesTypes] if _nodesTypes else []
# convert lists in _a into a single list
_nodeTypes = [item for sublist in _a for item in sublist]

_items = []

_items += [{
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
      *[{
        nodeCount = 1
        instanceType = helper._get_instance_type(_provSettings, n.instanceTypes or "2vCPU-4GB", _oxrProvZone)?[0]
        publicAccess = n.publicAccess
        if n.autoScaling:
          autoScaling = {
            enabled = n.autoScaling?.enabled
            minSize = n.autoScaling?.minCount
            maxSize = n.autoScaling?.maxCount
          }
        } for n in _nodeGroups
      ]
    ]
    # nodeGroups = [
    #   {
    #     nodeCount = 1
    #     instanceTypes = _nodeTypes
    #     publicAccess = True
    #     autoScaling = {
    #       enabled = True
    #       minSize = 1
    #       maxSize = 1
    #     }
    #   },
    #   {
    #     nodeCount = 1
    #     instanceTypes = _nodesTypes 
    #     publicAccess = False
    #     autoScaling = {
    #       enabled = True
    #       minSize = 1
    #       maxSize = 3
    #     }
    #   } if _nodesTypes else {}
    # ]
    providerRef = {
      platform = _oxrProvPlatform
      region = _oxrProvRegion
      zones = _oxrProvZones
    }
  }
}] if _oxrProvPlatform == "aws" else []

_items += [{
  apiVersion = "gcp.skycluster.io/v1alpha1"
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

    nodeGroups = [
      *[{
        nodeCount = 1
        instanceType = helper._get_instance_type(_provSettings, n.instanceTypes or "2vCPU-4GB", _oxrProvZone)?[0]
        publicAccess = n.publicAccess
        if n.autoScaling:
          autoScaling = {
            enabled = n.autoScaling?.enabled
            minSize = n.autoScaling?.minCount
            maxSize = n.autoScaling?.maxCount
          }
        } for n in _nodeGroups
      ]
    ]  
    # nodeGroups = [
    #   {
    #     nodeCount = 1
    #     instanceType = _nodeTypes?[0] # For GCP we use single instance type
    #     publicAccess = True
    #     autoScaling = {
    #       enabled = True
    #       minSize = 1
    #       maxSize = 1
    #     }
    #   },
    #   # {
    #   #   nodeCount = 1
    #   #   instanceTypes = _nodesTypes 
    #   #   publicAccess = False
    #   #   autoScaling = {
    #   #     enabled = True
    #   #     minSize = 1
    #   #     maxSize = 3
    #   #   }
    #   # } if _nodesTypes else {}
    # ]
    providerRef = {
      platform = _oxrProvPlatform
      region = _oxrProvRegion
      zones = _oxrProvZones
    }
  }
}] if _oxrProvPlatform == "gcp" else []


_nodeGroups = [n for n in oxr.spec?.nodeGroups if n]

_items += [{
  apiVersion = "os.skycluster.io/v1alpha1"
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
    podCidr = oxr.spec?.podCidr or Undefined

    nodeGroups = [
      # First node group is for controller node
      if oxr.spec?.controlPlane:
        {
          nodeCount = 1
          role = "control-plane"
          instanceType = helper._get_instance_type(_provSettings, oxr.spec?.controlPlane?.instanceType or "4vCPU-16GB", _oxrProvZone)?[0]
          publicAccess = True
          # highAvailability = oxr.spec?.controlPlane?.highAvailability
          if oxr.spec?.controlPlane?.autoScaling:
            autoScaling = {
              enabled = oxr.spec?.controlPlane?.autoScaling?.enabled
              minSize = oxr.spec?.controlPlane?.autoScaling?.minCount
              maxSize = oxr.spec?.controlPlane?.autoScaling?.maxCount
            }
        }, 
      # Rest of node groups (at least there must be one with public access)
      *[{
        nodeCount = 1
        role = "worker"
        instanceType = helper._get_instance_type(_provSettings, oxr.spec?.controlPlane?.instanceType or "2vCPU-4GB", _oxrProvZone)?[0]
        # instanceType = n.instanceTypes
        publicAccess = n.publicAccess
        if n.autoScaling:
          autoScaling = {
            enabled = n.autoScaling?.enabled
            minSize = n.autoScaling?.minCount
            maxSize = n.autoScaling?.maxCount
          }
        } for n in _nodeGroups
      ]
    ]

    providerRef = {
      platform = _oxrProvPlatform
      region = _oxrProvRegion
      zones = _oxrProvZones
    }
  }
}] if _oxrProvPlatform == "openstack" else []



_token = ocds?["xk8s"]?.Resource?.status?.token
_kubeconfig = ocds?["xk8s"]?.Resource?.status?.kubeconfig
_controllers = ocds?["xk8s"]?.Resource?.status?.controller
_clusterSecretName = ocds?["xk8s"]?.Resource?.status?.clusterSecretName

# Create a ProviderConfig for both Kubernetes and helm
# The kubeconfig is already stored in a secret by xkube object

secret = {
  apiVersion = "v1"
  kind = "Secret"
  metadata = {
    name = "xkube-secret"
    namespace = "default"
  }
  data = {
    token = _token
    kubeconfig = _kubeconfig
  }
}

# ###################### dxr ######################

dxr = {
  **option("params").dxr,
  status = {
    clusterName = ocds?["xk8s"]?.Resource?.metadata?.name
    if _kubeconfig:
      kubeconfig = _kubeconfig
    if _token:
      token = _token
    if _controllers:
      controller = [{
          privateIp = s.privateIp or Undefined
          publicIp = s.publicIp or Undefined
        } for s in _controllers
      ]
    if _clusterSecretName:
      clusterSecretName = _clusterSecretName
    podCidr = ocds?["xk8s"]?.Resource?.status?.podCidr
    serviceCidr = ocds?["xk8s"]?.Resource?.status?.serviceCidr
    # log = json.encode({
    #   token = _token or "NA"
    #   kubeconfig = _kubeconfig or "NA"
    #   controllers = [_c.privateIp for _c in _controllers] or "NA"
    # })
  }
}

items = [*_items, dxr]