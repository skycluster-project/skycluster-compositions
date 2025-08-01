import helper.v1alpha1.main as helper
import provider_helm.v1beta1 as helmv1beta1
import provider_kubernetes.v1alpha1 as k8sv1alpha1

oxr = option("params").oxr # observed composite resource
ocds = option("params")?.ocds # observed composed resources
# _dxr = option("params").dxr # desired composite resource
# dcds = option("params").dcds # desired composed resources

# assert oxr.metadata?.labels is not Undefined, "At least one label must be specified"
# assert "skycluster.io/managed-by" in oxr.metadata.labels, "Label 'skycluster.io/managed-by' must be specified"

ctx = option("params")?.ctx
assert ctx is not Undefined, "Context must be provided in the params"

_extraRes = ctx["apiextensions.crossplane.io/extra-resources"]
assert _extraRes is not Undefined, "Extra resources must be provided in the context"

_provCfgs = _extraRes["Providers"] or []
_helmProv = [cfg for cfg in _provCfgs if "provider-helm" in cfg.spec?.package]
_k8sProv = [cfg for cfg in _provCfgs if "provider-kubernetes" in cfg.spec?.package]

_ns = oxr.spec?.namespace or "skycluster-system"


_items = [
  helmv1beta1.ProviderConfig{
    metadata = {
      labels = {"skycluster.io/managed-by": "skycluster"}
      annotations = {
          **oxr.metadata?.annotations,
          **helper._set_resource_name("helmConfig"),
          "krm.kcl.dev/ready": "True"
      }
    }
    spec = {
      credentials = {
        source: "InjectedIdentity"
      }
    }
  }
] if _helmProv else []

_items += [
  k8sv1alpha1.ProviderConfig{
    metadata = {
      labels = {"skycluster.io/managed-by": "skycluster"}
      annotations = {
          **oxr.metadata?.annotations,
          **helper._set_resource_name("k8sConfig"),
          "krm.kcl.dev/ready": "True"
      }
    }
    spec = {
      credentials = {
        source: "InjectedIdentity"
      }
    }
  }
] if _k8sProv else []


_helmProvCfgName = ocds?["helmConfig"]?.Resource?.metadata?.name or Undefined
_k8sProvCfgName = ocds?["k8sConfig"]?.Resource?.metadata?.name or Undefined

_items += [
  helmv1beta1.Release{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        "skycluster.io/managed-by": "skycluster",
      },
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("submarinerBrokerRelease")
      }
    }
    spec = {
      forProvider = {
        chart = {
          name = "submariner-k8s-broker"
          repository = "https://submariner-io.github.io/submariner-charts/charts"
          version = "0.20.1"
        }
        namespace = _ns
        skipCreateNamespace = True
      }
      providerConfigRef = {
        name = _helmProvCfgName
      }
    }
  }
] if _helmProvCfgName or ocds?["submarinerBrokerRelease"] else []

_items += [
  {
    apiVersion = "skycluster.io/v1alpha1"
    kind = "XOverlay"
    metadata = {
      labels = {
        "skycluster.io/managed-by": "skycluster"
      }
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("xoverlay"),
      }
    }
    spec = {}
  }
] if oxr?.spec?.submariner?.enabled and helper._ready(ocds?["submarinerBrokerRelease"]) else []



dxr = [{
  **option("params").dxr,
  status.apiServer = oxr?.spec?.apiServer or Undefined,
  status.namespace = oxr?.spec?.namespace or "default",
  status.providerConfig = {
    helm = {
      name = _helmProvCfgName
    } if _helmProvCfgName else Undefined,
    kubernetes = {
      name = _k8sProvCfgName
    } if _k8sProvCfgName else Undefined
  } if _helmProvCfgName or _k8sProvCfgName else Undefined
}] 


items = _items + dxr