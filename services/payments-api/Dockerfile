# Multi-stage, and the first stage is the only place a language toolchain
# exists. There is none on the machine this was developed on, which is the
# point rather than an inconvenience: the build that runs here and the build
# that runs in the pipeline are the same build, so there is nowhere for "works
# on my machine" to hide.
#
# Both stages are pinned by digest rather than by tag. A tag can be moved to
# different content; a digest cannot. The same rule applies to the images this
# produces, which is why what gets committed for deployment is a digest too.

FROM golang@sha256:d530cf60723abf1ffae0cd16bb546b379ec0550d2f3815e5b16ed69dbc00fba4 AS build

WORKDIR /src

# Dependencies first and on their own layer, so that editing the source does
# not re-download them on every build.
COPY go.mod go.sum ./
RUN go mod download

COPY main.go ./

# Statically linked, because the runtime stage below has no C library to link
# against. Trimmed paths so the binary does not record the build machine's
# directory layout, and stripped so it carries no debug tables — both make the
# output identical between two builds of the same source, which is what makes a
# digest meaningful.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/payments-api .

# No shell, no package manager, no utilities. Nothing to exploit and nothing to
# patch, which also means a vulnerability scan has almost no surface to report
# on — the scan in the pipeline is then telling you about your own dependencies
# rather than about a base image somebody else has not updated.
FROM gcr.io/distroless/static-debian12@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab

COPY --from=build /out/payments-api /payments-api

# Already the default for this base image, and stated anyway so that a change
# of base image cannot quietly promote this to root.
USER nonroot:nonroot

EXPOSE 8080

ENTRYPOINT ["/payments-api"]
