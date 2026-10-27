ARG RUBY_VERSION=3.3
FROM ruby:${RUBY_VERSION}-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git libyaml-dev \
 && rm -rf /var/lib/apt/lists/*

ENV BUNDLE_PATH=/bundle \
    BUNDLE_JOBS=4 \
    RUBY_YJIT_ENABLE=1

WORKDIR /gem
