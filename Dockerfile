# CI/CD greps the following line to figure out the image build tag. Keep it as it is, including quotes.
ARG MASTODON_VERSION="v4.3.4"
FROM ghcr.io/mastodon/mastodon:${MASTODON_VERSION} AS mastodon

# TODO: locale-patcher could be merged with patcher, but debian does not have yq on their repos yet.
FROM alpine:3.21.3@sha256:a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c AS locale-patcher

RUN apk add --update jq yq && \
  mkdir -p /locales/config /locales/javascript && \
  mkdir /patches && \
  mkdir -p /output/config /output/javascript

# Reminder: Wicked docker COPY syntax will copy files inside folder, instead of folder itself.
COPY locale-patches/ /patches
COPY --from=mastodon /opt/mastodon/config/locales/ /locales/config
COPY --from=mastodon /opt/mastodon/app/javascript/mastodon/locales/ /locales/javascript

RUN cd /locales/javascript; \
  for lang in es en; do \
  for j in $lang*.json; do \
  echo Patching $j; \
  jq -s '.[0] * .[1]' /locales/javascript/$j /patches/javascript/$lang.json > /output/javascript/$j || exit 1; \
  done; \
  done

RUN cd /locales/config; \
  for lang in es en; do \
  for y in $lang*; do \
  echo Patching $y; \
  yq '. *= load("/patches/config/'$lang'.yaml")' /locales/config/$y > /output/config/$y || exit 1;\
  done; \
  done

FROM alpine:3.21.3@sha256:a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c AS patcher

COPY --from=mastodon /opt/mastodon /opt/mastodon

RUN apk add --update patch

COPY patches /patches
RUN find /patches -type f -name '*.patch' | while read p; do \
  echo "Applying $p" && \
  patch -p1 -d /opt/mastodon < $p || exit 1; \
  done

FROM mastodon AS rebuilder

USER root
ARG TARGETARCH
ARG NODE_VERSION="22.14.0"
ENV NODEARCH=${TARGETARCH/amd/x}
RUN curl -o- https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODEARCH}.tar.gz | tar -xzC /opt/
ENV PATH=${PATH}:/opt/node-v${NODE_VERSION}-linux-${NODEARCH}/bin/
RUN npm install -g yarn corepack && \
  corepack enable && \
  corepack prepare --activate && \
  yarn workspaces focus --production @mastodon/mastodon

WORKDIR /opt/mastodon

COPY --from=patcher /opt/mastodon /opt/mastodon
COPY --from=locale-patcher /output/javascript /opt/mastodon/app/javascript/mastodon/locales/
COPY --from=locale-patcher /output/config /opt/mastodon/config/locales/
COPY overlay/ /opt/mastodon/

# Prepend ai-robots.txt to upstream robots.txt.
RUN curl -sSL https://raw.githubusercontent.com/ai-robots-txt/ai.robots.txt/refs/heads/main/robots.txt | \
  cat - public/robots.txt > public/robots.txt.new && \
  mv public/robots.txt{.new,}

# Recompile assets, now with patches and overlays.
RUN SECRET_KEY_BASE_DUMMY=1 \
  bundle exec rails assets:precompile && \
  rm -rf /opt/mastodon/tmp /opt/mastodon/node_modules

FROM mastodon

# Copy all files, patched or not, from the patcher image.
# This copy is lightweight as identical files are reused. It does take a few kilobytes for modification times.
COPY --from=rebuilder /opt/mastodon /opt/mastodon
