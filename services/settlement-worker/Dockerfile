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
# directory layout, and stripped so it carries no debug tables.
#
# Those two flags make the *binary* reproducible. They do not make the image
# reproducible, and it is worth being precise about the difference because it
# is easy to assume otherwise. Building this source twice produces two
# different image digests: the image configuration carries a creation
# timestamp and the layer archives carry file modification times, none of
# which the compiler flags touch. Measured, not assumed — two builds of
# identical source, two digests.
#
# The practical consequence: re-running the build for a service whose source
# has not changed publishes a new digest and therefore redeploys identical
# code. The pipeline avoids this in normal operation by only building services
# whose files actually changed, so it bites on a manual re-run rather than on
# ordinary pushes. Making the image itself reproducible needs the newer builder
# with timestamp rewriting, which is a larger change than this phase needs.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/settlement-worker .

# No shell, no package manager, no utilities. Nothing to exploit and nothing to
# patch, which also means a vulnerability scan has almost no surface to report
# on — the scan in the pipeline is then telling you about your own dependencies
# rather than about a base image somebody else has not updated.
FROM gcr.io/distroless/static-debian12@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab

COPY --from=build /out/settlement-worker /settlement-worker

# Numeric, not the name "nonroot", and the distinction is not cosmetic.
# Kubernetes can only enforce runAsNonRoot when it can see a numeric user id in
# the image: given a name it cannot resolve, it refuses to start the container
# rather than risk running as root. Writing the name here overrode the numeric
# id this base image already declares and broke exactly the guarantee the line
# was added to provide.
USER 65532:65532

EXPOSE 8080

ENTRYPOINT ["/settlement-worker"]
