---
name: tp
description: "Trace a BUSFIN 8200 problem-set AI interaction with required before/after Git snapshots, append-only logging, and course-policy checks. Use only when explicitly invoked as @TP in ChatGPT or $tp in Codex at the beginning of a substantive request for this repository."
---

# Traceable Prompt

Use this skill only after explicit invocation. Its job is to preserve a contemporaneous, auditable record while enforcing the BUSFIN 8200 problem-set AI policy.

Before acting, read [references/course-ai-policy.md](references/course-ai-policy.md). The authoritative source is `Problem Sets AI Policy[57].pdf` at the repository root; if the summary and source ever differ, follow the source and the stricter interpretation. Do not weaken or replace the policy.

## Start the interaction

1. Confirm that the current workspace is a Git repository containing the policy document and `AI_INTERACTIONS.md`.
2. Identify the exact problem-set subitem, such as `1a`, from the prompt and assignment. Do not infer it merely from the active file. If it is unclear, if only a broad question number is given, or if the request spans items without clear attribution, ask the user to specify the item before any substantive work or snapshot commit.
3. Classify the requested assistance under the policy. Read only enough existing student work to establish whether the request is permitted and whether a required student-authored derivation, answer, or empirical specification exists. Reading for this preflight is allowed; do not yet check, solve, edit, debug, or otherwise perform substantive assistance.
4. Treat a disallowed substantive request as an interaction to audit: take the before snapshot, decline the prohibited assistance with a concise explanation, then log and take the after snapshot.

## Create the before snapshot

Inspect `git status --short --branch` first. Stop and ask the user how to proceed if the repository is in a merge, rebase, cherry-pick, revert, detached-HEAD, or conflicted state, or if staging everything would capture likely credentials, secrets, or clearly unrelated material. Do not silently omit files from the snapshot.

From the repository root, run:

```bash
.agents/skills/tp/scripts/snapshot.sh before "<item>"
```

The helper stages all non-ignored repository changes and creates a commit, including an empty commit when the tree has no changes. Record the full hash it prints as the Git commit before the interaction. If the commit, hook, signing, identity, permission, or hash operation fails, stop. Do not bypass hooks, disable signing, amend, squash, reset, or push.

Create only one before snapshot for an interaction. If the interaction pauses for a user decision, continue from the same before snapshot when the user replies.

## Perform only policy-permitted work

- For mathematics, check or diagnose the student's existing derivation. Do not generate, continue, complete, rewrite, replace, or directly implement a correction to the derivation. The student must decide and make corrections.
- For economic reasoning, critique the student's complete answer only after the student has written it in the solution source file. Explain identified issues, but do not generate, rewrite, or directly edit substantive economic reasoning. The student must decide and make revisions.
- For empirical work, verify that a sufficiently detailed student-authored specification or initial code exists in the repository before writing code. Implement, optimize, integrate, run, and debug code only within that design. Mechanical programming choices are allowed.
- If any mathematical, economic, empirical, or econometric choice is missing, name the ambiguity and ask the user to decide. Do not select or implement an option. For empirical work, require the user to update the specification or initial code with the decision before implementation.
- Formatting, grammar, exposition, and translation assistance may occur only after the substantive student work exists and may not generate, replace, or materially change its reasoning.

Keep a contemporaneous list of:

- every substantive prompt, user clarification, and user decision, preserving the wording verbatim and naming any attachments;
- the purpose evident from the request;
- every repository file inspected;
- every file directly modified;
- all errors, omissions, and ambiguities identified, including how user decisions resolved them;
- every substantive mathematical, economic, empirical, or econometric suggestion made; and
- every applicable assistance category.

Include material assistance and repository file access by any delegated agent in the same record. Do not attribute reasoning, intent, authorship, or understanding that the available record does not show.

## Group minor follow-ups narrowly

Do not group by default. Group only when the user explicitly asks, the request concerns the same exact item, it is in the same chat/work session, and it is limited to closely related minor debugging or formatting.

If grouping is requested before the initial interaction is finalized, keep the interaction open and delay the single log append and after snapshot until the user says the grouped sequence is finished.

If the initial entry was already finalized, accept a grouped continuation only when it is the last logical entry in `AI_INTERACTIONS.md`, there has been no intervening substantive interaction, and the user explicitly identifies it as a continuation. Treat the preceding after snapshot as the continuation's checkpoint. Append a clearly labeled continuation block at the physical end of that entry without changing any existing byte, retain the original before hash in the entry, verify the append against the preceding after hash, and create a new after snapshot. Otherwise start a new TP interaction. Never retroactively rewrite a finalized entry.

## Append the interaction record

Append one new entry at the end of `AI_INTERACTIONS.md`. Never modify, delete, reorder, combine, reformat, or replace existing content. If an earlier entry is wrong, leave it intact and append a separate correction entry.

Use this schema, replacing every placeholder. Use `None` rather than omitting a field. Choose a Markdown fence longer than any run of backticks in the prompt so the prompt remains verbatim.

````markdown
## TP interaction `<item>-<before-hash-prefix>` — `<timestamp with timezone>`

- **Problem set item:** `<exact item>`
- **Substantive prompt (verbatim):**

  ```text
  <prompt text after the TP invocation>
  ```

- **Purpose:** `<concise factual purpose>`
- **Git commit before interaction:** `<full hash>`
- **Assistance provided:** `<concise but complete description, including a policy refusal if applicable>`
- **Files inspected:** `<complete repository-relative list, or None>`
- **Files directly modified:** `<complete repository-relative list, including AI_INTERACTIONS.md, or None>`
- **Errors, omissions, or ambiguities identified:** `<details and resolution status, or None>`
- **Substantive mathematical, economic, or empirical suggestions:** `<details, or None>`
- **Type of assistance:** `<all applicable: checking mathematics; checking economic reasoning; empirical implementation; code debugging; formatting/translation; other>`
- **Grouped minor subsequent requests:** `<No as of initial close; any valid later continuation will be appended below, or Yes with each already-grouped verbatim follow-up prompt and the assistance provided>`
````

When a prompt has clarifications or user decisions, include each as a separate labeled verbatim block in the same entry. For a valid later grouped continuation, append its verbatim prompt, assistance, inspected and modified files, errors or ambiguities, substantive suggestions, and assistance types at EOF under the same interaction heading.

After appending, from the repository root run:

```bash
.agents/skills/tp/scripts/verify_log_append_only.sh "<full-before-hash>"
```

For an initial entry, use the full before hash. For a valid later grouped continuation, use the preceding after hash so the verifier proves that this continuation added bytes. If verification fails, stop and repair the audit record without substantive work. Preserve all prior bytes.

## Create the after snapshot

From the repository root, run:

```bash
.agents/skills/tp/scripts/snapshot.sh after "<item>"
```

This commit must include the appended log and all completed in-scope work, and must be created even if it is empty. If it fails, stop all new substantive work and tell the user that the audit trail is incomplete.

Conclude by reporting the item, the full before and after hashes, the log entry identifier, files directly modified, any unresolved ambiguity, and whether grouped follow-ups were included. Do not claim completion unless the log append and after snapshot both succeeded.
