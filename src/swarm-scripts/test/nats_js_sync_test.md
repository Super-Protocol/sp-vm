# Node 1
```bash
python3 /etc/swarm-service-launchers/test/nats_js_sync_test.py \
  --urls nats://10.13.44.67:4222 \
  --local-url nats://10.13.44.67:4222 \
  --id node-a \
  --subject test.sync \
  --stream SYNC_TEST \
  --timeout 60
```

# Node 2
```bash
python3 /etc/swarm-service-launchers/test/nats_js_sync_test.py \
  --urls nats://10.13.249.69:4222 \
  --local-url nats://10.13.249.69:4222 \
  --id node-b \
  --subject test.sync \
  --stream SYNC_TEST \
  --timeout 60
```
