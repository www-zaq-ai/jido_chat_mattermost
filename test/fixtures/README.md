# Media fixtures

`media.json` stores original bytes as Base64 so the tiny binary fixtures are
reviewable in text diffs. The JPEG, PNG, GIF, and WebP files are independently
encoded, valid 1×1 red images generated with ImageMagick:

```sh
magick -size 1x1 xc:red -strip jpeg:- | base64
```

Replace `jpeg` with `png`, `gif`, or `webp` for the other formats. The document is
UTF-8 text: `Original Mattermost document.` followed by a newline. No external
assets or credentials are included.
