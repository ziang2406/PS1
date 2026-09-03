# BUSFIN 8200 problem-set AI policy: operational summary

The authoritative source is `Problem Sets AI Policy[57].pdf` in the repository root. This summary exists to make the TP workflow reliable; it does not replace the source. If there is uncertainty or conflict, inspect the source and apply the stricter requirement.

## What counts as substantive

A request is substantive when it asks AI to check, critique, generate, revise, explain, debug, format, translate, summarize, or otherwise assist with a problem-set answer, derivation, empirical design, code, interpretation, or submission. Every substantive interaction must begin with explicit TP invocation and receive before/after Git snapshots plus an append-only `AI_INTERACTIONS.md` record.

Purely administrative navigation, command explanations, clarification of an already given answer without new work, or environment setup that does not affect problem-set substance does not require TP snapshots. Routine autocomplete, spelling, grammar, or formatting suggestions do not require a separate entry unless the user deliberately asks AI to produce, revise, critique, debug, or explain substantive work.

An item means an individual task within a question. In Problem Set 1, use the exact subitems `1a` through `1e`, `2a` through `2e`, `3a` through `3e`, or `4a` through `4e`.

## Mathematics

The student must first work through the derivation. AI may check that existing derivation, identify a possible error, explain why a particular step is incorrect, or diagnose a specific problem in work already attempted. AI may not continue the derivation or generate, rewrite, complete, replace, or directly correct it. The student determines and implements corrections.

After the substantive derivation exists, AI may improve exposition, grammar, or LaTeX formatting without generating, completing, replacing, or materially changing the mathematical reasoning. Translation from the student's handwritten derivation into LaTeX is permitted and must be documented as formatting/translation.

## Economic reasoning

The student must first develop the complete substantive answer and write it in the solution source file. AI may then evaluate it, identify errors, omissions, or inconsistencies, and explain its criticism. AI may not generate, rewrite, or directly edit the substantive economic reasoning. The student decides whether to accept criticism and makes all substantive changes.

After the answer exists, AI may improve exposition, grammar, or LaTeX formatting without generating, replacing, or materially changing the reasoning.

## Data analysis

The empirical design must come from the student. Before AI writes code, the repository must contain either a sufficiently detailed student-authored plain-language specification or initial student-authored code. When relevant, it must specify data sources, sample restrictions, variable definitions, timing conventions, transformations, econometric specifications, standard-error procedures, and desired outputs.

AI may translate that specification into working code, optimize and organize it, integrate it with the project, run it, and debug computational errors. AI may choose programming details that do not alter the empirical substance, such as data structures, functions, packages, loops versus vectorization, and code organization.

AI may not silently choose missing economically or econometrically meaningful details, including sample restrictions, timing, missing-value treatment, variable definitions, winsorization, regression specifications, or standard errors. It must identify the ambiguity. The student must decide and update the specification or initial code before AI implements that decision. A sparse starter script is not automatically a sufficient design specification.

## Audit requirements

All problem-set AI use must occur in the single designated project/workspace. For every substantive interaction:

1. identify the exact item;
2. commit the entire current non-ignored repository state before assistance, using an empty commit if necessary;
3. provide only policy-permitted assistance and leave substantive decisions to the student;
4. append a complete entry to `AI_INTERACTIONS.md` without altering prior entries; and
5. commit the repository state after the interaction, using an empty commit if necessary.

If a required snapshot or log operation fails, stop and fix the record before continuing substantive work. Do not delete, rewrite, combine, or selectively omit interaction entries. Correct a bad entry by appending a new correction entry.

Closely related minor debugging or formatting requests may be grouped only when the user explicitly asks, they concern the same exact item, occur in the same work session, and are documented together. Never use grouping to absorb a new substantive task or design decision.

The final `AI_USAGE.md` summary is a separate end-of-problem-set task. It does not replace contemporaneous entries in `AI_INTERACTIONS.md`.
