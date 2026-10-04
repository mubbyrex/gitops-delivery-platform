# Architecture

The system as built: what runs where, which component owns which resources,
and where the boundaries between them sit.

Solid outlines are built. Dashed outlines are planned and do not exist yet.
Colour shows ownership — blue for what the provisioning tooling creates, green
for what the delivery controller creates, amber for what neither of them
creates.

## The platform

![Platform architecture](diagrams/platform-architecture.png)

## How a release reaches each workload

Export page 2 from the drawing as diagrams/release-paths.png, then
     uncomment the line below.
![Release paths](diagrams/release-paths.png)


## Editing these

The source is [`diagrams/kestrel-pay-architecture.drawio`](diagrams/kestrel-pay-architecture.drawio),
a two-page drawing. Open it with [draw.io](https://www.drawio.com), change what
has moved, and export each page again over the images above.

A `.drawio` file is not an image. Source control will show it as XML and so will
anything else, which is why the exported pictures are committed alongside it.
