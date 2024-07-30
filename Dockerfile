FROM sample-app-ruby

EXPOSE 8080

ENTRYPOINT ["./wait-for-couchbase.sh", "bin/server"]