FROM alpine:3.23.2
RUN apk add --no-cache crystal shards git bash libressl-dev
WORKDIR /work/bootstrap-qcow2
CMD ["bash"]

