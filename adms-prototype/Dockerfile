FROM golang:1.22-alpine AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags '-s -w' \
    -o /adms-controller ./cmd/controller/

FROM alpine:3.19

RUN apk add --no-cache \
    nftables \
    e2fsprogs \
    audit \
    curl \
    jq \
    openssl

COPY --from=builder /adms-controller /usr/local/bin/adms-controller
COPY breakglass/reset.sh /usr/local/sbin/adms-breakglass
RUN chmod 700 /usr/local/sbin/adms-breakglass

RUN mkdir -p /etc/adms /var/run/adms /var/log/adms

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/adms-controller"]
CMD ["--tau=1s", "--q=60", "--delta=3", "--sensor=tetragon", "--http=:8080"]
