# sp-vm

## build
To get working mounts during docker build process use:
```bash
docker buildx create --use --name insecure-builder --buildkitd-flags '--allow-insecure-entitlement security.insecure'
docker buildx build -t sp-vm --allow security.insecure . --output type=local,dest=./out
```
