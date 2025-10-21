# CI/CD greps the following line to figure out the image build tag. Keep it as it is, including quotes.
ARG MASTODON_VERSION="v4.4.8"
FROM ghcr.io/mastodon/mastodon:${MASTODON_VERSION} AS mastodon

# TODO: locale-patcher could be merged with patcher, but debian does not have yq on their repos yet.
FROM alpine:3.22.2@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412 AS locale-patcher

RUN <<EOF
  set -eo pipefail

  apk add --update jq yq
  mkdir -p /locales/config /locales/javascript
  mkdir /patches
  mkdir -p /output/config /output/javascript
EOF

# Reminder: Wicked docker COPY syntax will copy files inside folder, instead of folder itself.
COPY locale-patches/ /patches
COPY --from=mastodon /opt/mastodon/config/locales/ /locales/config
COPY --from=mastodon /opt/mastodon/app/javascript/mastodon/locales/ /locales/javascript

RUN <<EOF
  set -eo pipefail

  cd /locales/javascript
  for lang in es en; do
    for j in $lang*.json; do
      echo Patching $j
      jq -s '.[0] * .[1]' /locales/javascript/$j /patches/javascript/$lang.json > /output/javascript/$j
    done
  done
EOF

RUN <<EOF
  set -eo pipefail

  cd /locales/config
  for lang in es en; do
    for y in $lang*; do
      echo Patching $y
      yq '. *= load("/patches/config/'$lang'.yaml")' /locales/config/$y > /output/config/$y
    done
  done
EOF

FROM alpine:3.22.2@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412 AS patcher

COPY --from=mastodon /opt/mastodon /opt/mastodon

RUN apk add --update patch

COPY patches /patches
RUN <<EOF
  set -eo pipefail

  find /patches -type f -name '*.patch' | while read p; do
    echo "Applying $p"
    patch -p1 -d /opt/mastodon < $p
  done
EOF

FROM mastodon AS rebuilder

USER root
ARG TARGETARCH
ARG TARGETPLATFORM
ARG NODE_VERSION="22.21.0"
ENV NODEARCH=${TARGETARCH/amd/x}
RUN curl -o- https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODEARCH}.tar.gz | tar -xzC /opt/
ENV PATH=${PATH}:/opt/node-v${NODE_VERSION}-linux-${NODEARCH}/bin/
RUN \
  --mount=type=cache,id=corepack-cache-${TARGETPLATFORM},target=/usr/local/share/.cache/corepack,sharing=locked \
  --mount=type=cache,id=yarn-cache-${TARGETPLATFORM},target=/usr/local/share/.cache/yarn,sharing=locked \
  <<EOF
  set -eo pipefail

  npm install -g yarn corepack
  corepack enable
  corepack prepare --activate
  yarn workspaces focus --production @mastodon/mastodon
EOF

WORKDIR /opt/mastodon

COPY --from=patcher /opt/mastodon /opt/mastodon
COPY --from=locale-patcher /output/javascript /opt/mastodon/app/javascript/mastodon/locales/
COPY --from=locale-patcher /output/config /opt/mastodon/config/locales/
COPY overlay/ /opt/mastodon/

# Prepend ai-robots.txt to upstream robots.txt.
RUN <<EOF
  set -eo pipefail

  curl -sSL https://raw.githubusercontent.com/ai-robots-txt/ai.robots.txt/refs/heads/main/robots.txt |
    cat - public/robots.txt > public/robots.txt.new
  mv public/robots.txt{.new,}
EOF

# Recompile assets, now with patches and overlays.
RUN <<EOF
  set -eo pipefail

  export SECRET_KEY_BASE_DUMMY=1
  bundle exec rails assets:precompile
  rm -rf /opt/mastodon/tmp /opt/mastodon/node_modules
EOF

FROM mastodon

# Copy all files, patched or not, from the patcher image.
# This copy is lightweight as identical files are reused. It does take a few kilobytes for modification times.
COPY --from=rebuilder /opt/mastodon /opt/mastodon
