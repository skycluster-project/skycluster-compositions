import json
import base64
import helper.v1alpha1.main as helper
import provider_helm.v1beta1 as helmv1beta1
import provider_kubernetes.v1alpha1 as k8sv1alpha1
import provider_kubernetes.v1alpha2 as k8sv1alpha2

oxr = option("params").oxr # observed composite resource
ocds = option("params")?.ocds # observed composed resources
# _dxr = option("params").dxr # desired composite resource
# dcds = option("params").dcds # desired composed resources

ctx = option("params")?.ctx
assert ctx is not Undefined, "Context must be provided in the params"

_extraRes = ctx["apiextensions.crossplane.io/extra-resources"]
assert _extraRes is not Undefined, "Extra resources must be provided in the context"

_keypair = _extraRes["Secrets"]?[0]
assert _keypair is not Undefined, "Default keypair must be provided in the extra resources"

_provCfgs = _extraRes["Providers"] or []
_helmProv = [cfg for cfg in _provCfgs if "provider-helm" in cfg.spec?.package]
_k8sProv = [cfg for cfg in _provCfgs if "provider-kubernetes" in cfg.spec?.package]

_ns = oxr.spec?.namespace or "skycluster-system"
_apiServer = oxr.spec?.apiServer or Undefined
assert _apiServer is not Undefined, "Broker public IP and port must be provided"


# Helm Provider Config
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

# Kubernetes Provider Config
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

# submariner presetup
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
] if (oxr?.spec?.submariner?.enabled and _helmProvCfgName) or ocds?["submarinerBrokerRelease"] else []

# submariner overlay setup
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



_apiServerForHeadscale = _apiServer.split(":")[0]
assert _apiServerForHeadscale, "API server address must be provided"

# Pod Generating Headscale Certificate
_items += [
  k8sv1alpha2.Object{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        "skycluster.io/managed-by": "skycluster",
      },
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("headscaleCertGenPod")
      }
    }
    spec =  {
      forProvider.manifest = {
        apiVersion = "v1"
        kind = "Pod"
        metadata = { 
          name = "headscale-cert-gen",
          namespace = _ns if _ns else "skycluster-system",
          labels = {
            **oxr.metadata?.labels,
            "skycluster.io/managed-by": "skycluster",
            "skycluster.io/pod-type": "headscale-cert-gen"
          },
          annotations = {
            **oxr.metadata?.annotations,
          }
        }
        spec = {
          restartPolicy = "Never"
          containers = [{
            name = "headscale-cert-gen"
            image = "etesami/ca-signer:latest"
            imagePullPolicy = "Always"
            env = [
              {
                name = "CA_SECRET_NAME"
                value = "skycluster-self-ca"
              },
              {
                name = "OUTPUT_SECRET_NAME"
                value = "headscale-cert"
              },
              {
                name = "NAMESPACE"
                value = _ns if _ns else "skycluster-system"
              },
              {
                name = "CERT_COMMON_NAME"
                value = "skycluster.local"
              },
              {
                name = "CERT_SANS"
                value = "DNS:skycluster.local,IP:{}".format(_apiServerForHeadscale)
              }
            ]
          }]
          serviceAccountName = "skycluster-sva"
          restartPolicy = "Never"
        }
      }
      providerConfigRef = {
        name = _k8sProvCfgName
      }
    }
  }
] if (_k8sProvCfgName and _apiServerForHeadscale) or ocds?["headscaleCertGenPod"] else []


# Headscale-server Deployment
_items += [
  # Init and main headscale-server containers
  k8sv1alpha2.Object{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        "skycluster.io/managed-by": "skycluster",
      },
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("headscaleServerDeployment")
      }
    }
    spec =  {
      forProvider.manifest = {
        apiVersion = "apps/v1"
        kind = "Deployment"
        metadata = { 
          name = "headscale-server",
          namespace = _ns if _ns else "skycluster-system",
          labels = {
            **oxr.metadata?.labels,
            "skycluster.io/managed-by": "skycluster",
            "skycluster.io/deploy-type": "headscale-server"
          },
          annotations = {
            **oxr.metadata?.annotations,
          }
        }
        spec = {
          selector.matchLabels = {"app": "headscale-server"}
          template = {
            metadata.labels = {"app": "headscale-server"}
            spec = {
              volumes = [
                {
                  name = "config-volume"
                  persistentVolumeClaim = {
                    claimName = "headscale-config-pvc"
                  }
                },
                {
                  name = "headscale-storage",
                  persistentVolumeClaim = {
                    claimName = "headscale-pvc"
                  }
                }
              ]
              initContainers = [{
                name = "headscale-init"
                image = "etesami/headscale-init:latest"
                env = [
                  {
                    name = "SECRET_NAMESPACE"
                    value = _ns if _ns else "skycluster-system"
                  },
                  {
                    name = "SECRET_NAME"
                    value = "headscale-cert"
                  },
                  {
                    name = "HEADSCALE_SERVER_URL"
                    value = "https://{}:8080".format(_apiServerForHeadscale)
                  }
                ]
                volumeMounts = [{
                  name = "config-volume"
                  mountPath = "/config"
                }]
                workingDir = "/app"
              }, {
                name = "headscale-config-viewer"
                image = "alpine:3.22.1"
                command = ["/bin/sh", "-c"]
                args = ["ls /etc/headscale && cat /etc/headscale/config.yml"]
                volumeMounts = [{
                  name = "config-volume"
                  mountPath = "/etc/headscale"
                }]
              },{
                name = "headscale-init-config",
                image = "etesami/headscale-init-config:latest",
                env = [
                  {
                    name = "HEADSCALE_SERVER_URL"
                    value = "https://{}:8080".format(_apiServerForHeadscale)
                  },
                ]
                volumeMounts = [{
                  name = "config-volume",
                  mountPath = "/etc/headscale"
                }, {
                  name = "headscale-storage",
                  mountPath = "/var/lib/headscale"
                }]
              }]
              containers = [{
                name = "headscale-server"
                image = "etesami/headscale-server:c3354cb"
                volumeMounts = [{
                  name = "config-volume"
                  mountPath = "/etc/headscale"
                }, {
                  name = "headscale-storage"
                  mountPath = "/var/lib/headscale"
                }]
                args = [
                  "serve",
                  "--config",
                  "/etc/headscale/config.yml"
                ]
                ports = [{
                  containerPort = 8080
                  protocol = "TCP"
                }]
              }]
              serviceAccountName = "skycluster-sva"
            }
          }
        }
      }
      providerConfigRef = {
        name = _k8sProvCfgName
      }
    }
  }
  
  # Service for headscale-server
  k8sv1alpha2.Object{
    metadata = {
      labels = {
        **oxr.metadata?.labels,
        "skycluster.io/managed-by": "skycluster",
      },
      annotations = {
        **oxr.metadata?.annotations,
        **helper._set_resource_name("headscaleServerService")
      }
    }
    spec = {
      forProvider.manifest = {
        apiVersion = "v1"
        kind = "Service"
        metadata = { 
          name = "headscale-server",
          namespace = _ns if _ns else "skycluster-system",
          labels = {
            **oxr.metadata?.labels,
            "skycluster.io/managed-by": "skycluster",
            "skycluster.io/service-type": "headscale-server"
          },
          annotations = {
            **oxr.metadata?.annotations,
          }
        }
        spec = {
          type = "NodePort"
          ports = [{
            port = 8080
            targetPort = 8080
            nodePort = 30080
          }]
          selector = {"app": "headscale-server"}
        }
      }
      providerConfigRef = {
        name = _k8sProvCfgName
      }
    }
  }

] if helper._ready(ocds?["headscaleCertGenPod"]) or ocds?["headscaleServerDeployment"] else []


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
  status.submariner.connectionSecretName = ocds?["xoverlay"]?.Resource?.status?.connectionSecretName or Undefined
  status.headscale.connectionSecretName = "headscale-connection-secret",
  status.keypair = {
    secretName = _keypair.metadata?.name or Undefined,
    secretNamespace = _keypair.metadata?.namespace or "skycluster-system",
    publicKey = json.decode(base64.decode(_keypair.data?.config))?.publicKey or Undefined
  }
}] 


items = _items + dxr