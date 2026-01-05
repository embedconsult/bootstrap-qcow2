# bootstrap-qcow2

TODO: Write a description here

## Installation

TODO: Write installation instructions here

## Usage

### Build a self-hosting Docker image (Crystal 1.18.2 from source)

The repository provides `Dockerfile.selfhost`, which produces an Alpine-based container containing:
- the project sources
- the Crystal toolchain built from source (v1.18.2), clang/lld, and build essentials
- a `bootstrap-selfhost` CLI that can rebuild the project from source inside the container

Build the image (tag `bootstrap-qcow2-selfhost` by default):
```sh
docker build -f Dockerfile.selfhost -t bootstrap-qcow2-selfhost .
```

Run the container to rebuild everything from source:
```sh
docker run --rm -it bootstrap-qcow2-selfhost rebuild
```

You can also verify required tool availability:
```sh
docker run --rm -it bootstrap-qcow2-selfhost verify
```

## Development

TODO: Write development instructions here

## Contributing

1. Fork it (<https://github.com/your-github-user/bootstrap-qcow2/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jason Kridner](https://github.com/your-github-user) - creator and maintainer
