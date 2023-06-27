FROM --platform=linux/amd64 ruby:3.2.1-bullseye

LABEL maintainer="Couchbase"

WORKDIR /app

ADD . /app

RUN apt-get update -y && apt-get install -y \
    jq curl

# Build cmake from source
RUN mkdir /opt/cmake-3.26.1  \
    && rm -rf /var/lib/apt/lists/* \
    && wget https://github.com/Kitware/CMake/releases/download/v3.26.1/cmake-3.26.1-linux-x86_64.sh \
      -q -O /tmp/cmake-install.sh \
    && chmod u+x /tmp/cmake-install.sh \
    && /tmp/cmake-install.sh --skip-license --prefix=/opt/cmake-3.26.1 \
    && rm /tmp/cmake-install.sh \
    && ln -s /opt/cmake-3.26.1/bin/* /usr/local/bin

# Install ruby gems
RUN bin/setup

EXPOSE 8080

ENTRYPOINT ["./wait-for-couchbase.sh", "bin/server"]