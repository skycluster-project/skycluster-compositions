# SkyCluster Composition


In develop environment, set the source to the .k file containing the composition definition:

```bash
spec:
  source: /home/ubuntu/skycluster-project/skycluster-compositions/aws.skycluster.io/apis/xgateways/kcl/main.k
```

Once the KCL configuration is finalized and ready to be shipped within the composition, place the raw 
configuration directly as the `source` along with `dependencies` field:

```bash
spec:
  dependencies: |
    provider-aws = { git = "https://github.com/skycluster-project/kcl-modules", version = "0.0.1" }
  source: |
    import provider_aws.ec2.v1beta1.vpc as ec2vpc
    ...
```

## Up Cli Commands

```bash
up init project skycluster.io
up generate example
up xrd generate examples/xskycluster/example.yaml 
up composition generate apis/xskyclusters/definition.yaml


kcl mod init
kcl mod update
```