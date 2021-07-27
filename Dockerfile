FROM ruby:3.0.0

LABEL maintainer="Couchbase"

WORKDIR /app

ADD . /app

RUN apt-get update -y && apt-get install -y \
    jq curl

# Install ruby gems
RUN bin/setup

EXPOSE 8080

ENTRYPOINT ["./wait-for-couchbase.sh", "bin/server"]