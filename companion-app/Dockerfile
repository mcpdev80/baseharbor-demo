FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/companion .

FROM alpine:3.22
RUN addgroup -S app && adduser -S -G app -u 10001 app
COPY --from=build /out/companion /usr/local/bin/companion
USER 10001:10001
EXPOSE 8081
ENTRYPOINT ["/usr/local/bin/companion"]
