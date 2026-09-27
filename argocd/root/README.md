# Root path

This directory is what the delivery controller watches. Everything the cluster
runs is expected to arrive by being committed here, or by being referenced from
something committed here.

It is close to empty on purpose. The controller is installed and pointed at
this path before there is anything for it to manage, so that the handover from
the provisioning tooling to the controller is a commit rather than a rebuild.
Filling it is the next piece of work, not a missing piece of this one.

Only manifests are read from here. This file is prose and is ignored.
