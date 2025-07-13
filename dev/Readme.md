# Readme

```bash
crossplane render \
  ../aws.skycluster.io/examples/xsetup/example.yaml \
  ../aws.skycluster.io/apis/xsetups/composition.yaml \
  function.yml \
  --extra-resources extra-res.yml 


export EXAMPLE=../submariner.skycluster.io/examples/broker/example.yaml
export COMPOSITION=../submariner.skycluster.io/apis/brokers/composition.yaml
crossplane render $EXAMPLE $COMPOSITION function.yml --extra-resources extra-res.yml 
```