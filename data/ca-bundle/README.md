# CA bundle

This directory stores the single PEM bundle used to seed
`/etc/ssl/certs/ca-certificates.crt` inside the generated rootfs.

Source: the Mozilla CA Certificate Program bundle as published by curl.se
(<https://curl.se/ca/cacert.pem>). This copy was seeded from the build host's
`/etc/ssl/certs/ca-certificates.crt` on 2026-01-21.

Refresh steps:
- Download the latest bundle from curl.se into
  `data/ca-bundle/ca-certificates.crt`.
- Ensure the build remains reproducible by documenting the update date here.
