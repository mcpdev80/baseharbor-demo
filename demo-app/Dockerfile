FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/demo .

FROM alpine:3.22
RUN apk add --no-cache ca-certificates && addgroup -S app && adduser -S -G app -u 10001 app
COPY --from=build /out/demo /usr/local/bin/demo
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/demo"]
