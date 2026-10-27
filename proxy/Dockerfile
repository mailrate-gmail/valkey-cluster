FROM alpine:3.20 AS build

ARG REDIS_CLUSTER_PROXY_REF=unstable

RUN apk add --no-cache build-base git linux-headers

RUN git clone --depth 1 --branch "$REDIS_CLUSTER_PROXY_REF" \
      https://github.com/RedisLabs/redis-cluster-proxy.git /src

WORKDIR /src
# redis-cluster-proxy is older C code; -fcommon keeps it buildable with GCC 10+.
RUN make CFLAGS="-fcommon" -j"$(nproc)" \
  && install -m 0755 src/redis-cluster-proxy /usr/local/bin/redis-cluster-proxy

FROM valkey/valkey:8-alpine

RUN apk add --no-cache libatomic libgcc

COPY --from=build /usr/local/bin/redis-cluster-proxy /usr/local/bin/redis-cluster-proxy

ENTRYPOINT ["redis-cluster-proxy"]
