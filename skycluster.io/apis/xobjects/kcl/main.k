import json
import helper.v1alpha1.main as helper
import provider_kubernetes.v1alpha2 as k8sv1a2


oxr = option("params").oxr # observed composite resource
ocds = option("params")?.ocds # observed composed resources

ctx = option("params")?.ctx
assert ctx is not Undefined, "Context must be provided in the params"

assert oxr.spec.providerConfigRef?.name is not Undefined, "providerConfigRef name must be provided in the composite resource"
assert oxr.spec.manifest is not Undefined, "manifest must be provided in the composite resource"

_items = []
_items += [_helper_object()]

_objStatus = ocds?["object"]?.Resource?.status

dxr = [{
  **option("params").dxr,
  status = {
    if _objStatus and _objStatus.conditions:
      conditions = [{
        type = cond.type
        status = cond.status
      } for cond in _objStatus?.conditions]
  }
}] 

items = _items + dxr


_helper_object = lambda {
  k8sv1a2.Object{
    metadata = {
      labels = oxr.metadata.labels
      annotations = {
        **oxr.metadata.annotations,
        **helper._set_resource_name("object")
      }
    }
    spec =  {
      forProvider.manifest = oxr.spec.manifest
      providerConfigRef = {
        name = oxr.spec.providerConfigRef.name
      }
    }
  }
}
