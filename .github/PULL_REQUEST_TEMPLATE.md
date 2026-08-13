## What changed

<!-- One or two sentences. What does this do, not how. -->

## Why

<!-- Link the issue or ADR. If this is an architectural choice, it needs an ADR
     in docs/adr/ before merge, not after. -->

## Does this touch `config/`?

<!-- Delete this section if not.

     Merging to main IS the deploy. Config Sync applies the branch head within
     15 seconds and there is no apply step in between. -->

- [ ] I know which objects this adds, changes, or **removes** (Config Sync prunes what it previously applied)
- [ ] Any new constraint is on `dryrun`, or I have read its violations on a live cluster and stated below what enforcing it breaks
- [ ] Nothing here is environment-specific (these files are applied literally, with no templating)
- [ ] No Secret, token, or credential in the diff

## Author checklist

- [ ] I read the full `terraform plan` output, including every `must be replaced` reason
- [ ] No resource holding data is being destroyed or replaced (or the `destroy-approved` label is applied and the reason is stated below)
- [ ] I can explain what every line of this diff does without looking it up
- [ ] Cost impact is understood (note anything recurring below)
- [ ] Provider and module versions are pinned, lock file committed

## Cost impact

<!-- "None", or the recurring monthly delta and what is driving it. -->

## Rollback

<!-- For config/, this is a revert and one sync interval. Say so.
     For terraform/, "revert the commit" only counts if that is actually safe
     for the resources involved. -->
