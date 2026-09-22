# CI/CD greps the following line to figure out the image build tag. Keep it as it is, including quotes.
ARG MASTODON_VERSION="v4.7.1"
FROM ghcr.io/mastodon/mastodon:${MASTODON_VERSION} AS mastodon

FROM mastodon AS patcher

USER root
ARG TARGETARCH
ARG YQ_VERSION="4.53.6"
# Debian's yq is the Python/jq-wrapper (kislyuk/yq), incompatible with the load()/*= syntax
# below. Fetch the real (mikefarah) binary instead.
ADD https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${TARGETARCH} /usr/local/bin/yq

RUN <<EOF
  set -eo pipefail

  chmod +x /usr/local/bin/yq
  apt-get update
  apt-get install -y --no-install-recommends jq patch
  rm -rf /var/lib/apt/lists/*
EOF

# Reminder: Wicked docker COPY syntax will copy files inside folder, instead of folder itself.
COPY locale-patches/ /locale-patches
COPY patches /patches

RUN <<EOF
  set -eo pipefail

  cd /opt/mastodon/app/javascript/mastodon/locales
  for lang in es en; do
    for j in $lang*.json; do
      echo Patching $j
      jq -s '.[0] * .[1]' $j /locale-patches/javascript/$lang.json > $j.new
      mv $j.new $j
    done
  done
EOF

RUN <<EOF
  set -eo pipefail

  cd /opt/mastodon/config/locales
  for lang in es en; do
    for y in $lang*; do
      echo Patching $y
      yq '. *= load("/locale-patches/config/'$lang'.yaml")' $y > $y.new
      mv $y.new $y
    done
  done
EOF

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
ARG NODE_VERSION="24.21.0"
ENV NODEARCH=${TARGETARCH/amd/x}
ADD https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODEARCH}.tar.gz /tmp/node.tar.gz
RUN <<EOF
  set -eo pipefail

  tar -xzC /opt/ -f /tmp/node.tar.gz
  rm /tmp/node.tar.gz
EOF
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
COPY overlay/ /opt/mastodon/

# Prepend ai-robots.txt to upstream robots.txt.
ADD https://raw.githubusercontent.com/ai-robots-txt/ai.robots.txt/refs/heads/main/robots.txt /tmp/ai-robots.txt
RUN <<EOF
  set -eo pipefail

  cat /tmp/ai-robots.txt public/robots.txt > public/robots.txt.new
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
