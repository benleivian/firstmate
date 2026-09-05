---
name: ddevclean
description: >-
  Safely preview or reclaim stale DDEV projects and Docker resources created by
  Firstmate and no-mistakes. Use when the captain invokes /ddevclean.
user-invocable: true
metadata:
  internal: true
---

# ddevclean

Run `bin/fm-ddev-clean.sh` for `/ddevclean`.
Run `bin/fm-ddev-clean.sh --apply` immediately only for `/ddevclean apply`.
For every other invocation, run the dry-run first and summarize the stale projects, returned worker copies, and Docker cleanup in plain English.

For invocations other than `/ddevclean apply`, wait for the captain's explicit go after the dry-run before applying cleanup.
Read the [cleanup script header](../../../bin/fm-ddev-clean.sh) for project selection and host-wide cleanup scope before presenting the preview.

After an applied run, report the script's summary and the `docker system df` result as what was reclaimed or remains.
If DDEV or Docker is unavailable, state the concrete missing tool and make no cleanup claim.
