# images

This repository contains a collection of minimal, custom container images. Each image is built and
published automatically to the GitHub Container Registry (GHCR) when a new version tag is pushed to
GitHub.

## Features

- 📁 One subfolder per image inside `images/` (e.g., `images/restic/`, `images/tini/`)
- ⚙️ Automatic builds with GitHub Actions
- 🔖 Semantic version tags based on installed software and base image versions
- 🐋 Published to [GHCR](https://ghcr.io) under `ghcr.io/infinityvault/<image-name>`

## Repository Structure

```
.
├── images/
│   ├── restic/
│   │   └── Dockerfile
│   ├── tini/
│   │   └── Dockerfile
└── README.md
```

Each folder contains:
- A `Dockerfile` using a base image (e.g. `restic/restic:0.18.0`, `alpine:3.21.3`)
- Optional: other assets required for the image build

## Image Tags

Images are published with two tags:

1. **Versioned tag**: Based on the Git tag
   Example: `0.19.0-alpine-3.21.3`
2. **`latest` tag**: Always updated on changes to the image

Images can optionally define variant tags via `build-variants.json` in their image folder.

When this file exists, the workflow first builds and publishes the default image using the
Dockerfile's default build args:

- Tag format: `:<normalized-version>`
- Also tagged as: `:latest`

It then builds and publishes one tag per variant using:

- Tag format: `:<normalized-version>-<tagSuffix>`
- Build args: values from the variant's `buildArgs` object

Git tags use the format `<image-name>_<version>`; for example, `restic-backup_0.0.5` publishes
`ghcr.io/infinityvault/restic-backup:0.0.5`.

Example `images/restic-backup/build-variants.json`:

```json
{
  "variants": [
    {
      "tagSuffix": "pg16",
      "buildArgs": {
        "POSTGRES_CLIENT_PKG": "postgresql16-client"
      }
    },
    {
      "tagSuffix": "mysql",
      "buildArgs": {
        "MYSQL_CLIENT_PKG": "mysql-client"
      }
    }
  ]
}
```

If `build-variants.json` is not present, the default tags are published as before:

- `:<normalized-version>`
- `:latest`

## Pulling Images

```bash
docker pull ghcr.io/infinityvault/restic:0.18.0
docker pull ghcr.io/infinityvault/tini:0.19.0-alpine-3.21.3
```

## Adding a New Image

1. Create a new folder under `images/` (e.g. `images/htop/`)
2. Add a `Dockerfile` using this pattern:

```Dockerfile
FROM alpine:3.21.3

RUN apk add --no-cache htop=3.2.1
```

3. Open a PR and merge to `main`
4. Tag the commit (e.g. `htop_3.2.1-alpine-2.21.3`) and push the tag to GitHub. The image will be
   built and published automatically after that.

## Contributing

Feel free to open issues or submit pull requests for new images or improvements.

## License

[MIT](./LICENSE)
