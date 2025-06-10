```bash
docker build -t test .

docker run --privileged --rm -it -v $(pwd)/files:/files test bash 
```
