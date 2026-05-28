#!/command/with-contenv bash
# PerkOS shutdown hook for the Hermes image.
#
# Runs as part of s6-overlay's cont-finish phase: AFTER all
# supervised services have stopped and BEFORE s6 exits. Runs as
# root.
#
# We use this window to tar $HERMES_HOME and push it to S3 so the
# next wake of this agent (different ECS task placement, possibly
# different host) can restore the same state via cont-init.d's
# restore step.
#
# Timing budget: ECS Fargate's stopTimeout (set to 300s on PerkOS
# agent task defs) is the hard ceiling for shutdown — s6 draining
# services + our snapshot + s6 exiting must all fit inside it.
# Today's snapshot is a small tar + a single S3 PUT and reliably
# completes in well under 60s.
#
# Exit code is ignored by s6 (cont-finish.d scripts are best-effort
# by contract) — we still print on failure so it shows up in
# `docker logs` and CloudWatch.

set -eu

echo "perkos-finish: services stopped, taking final snapshot..."
if /usr/local/bin/perkos-snapshot.sh; then
  echo "perkos-finish: snapshot complete"
else
  echo "perkos-finish: snapshot failed (state will be lost on wake)"
fi
