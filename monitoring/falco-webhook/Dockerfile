# monitoring/falco-webhook/Dockerfile
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod .
COPY main.go .
RUN CGO_ENABLED=0 go build -o /falco-webhook .

FROM gcr.io/distroless/static-debian12
COPY --from=build /falco-webhook /falco-webhook
EXPOSE 8080
ENTRYPOINT ["/falco-webhook"]
