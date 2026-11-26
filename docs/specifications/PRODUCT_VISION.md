# Product Vision

## Problem

Software work involving AI often requires people to divide requests into
smaller tasks, coordinate tools and reviewers, run checks, and track the
resulting changes and evidence across multiple sessions.

## Vision

Syntila helps people direct that work through persistent Spaces and
Threads. People discuss intent, start constrained Workflows, observe
execution, review changes and evidence, and decide what happens next. Syntila
keeps ownership of shared state and validates each transition.

Syntila Cloud coordinates shared product state. Syntila Connect provides
the local execution environment on a user's computer. Workers run through a
generic CLI Worker Engine and signed Worker Profiles, with provider CLI
credentials staying on the user's machine.

## Quality philosophy

Syntila does not guarantee AI correctness. It makes work inspectable and
acceptance evidence-based through:

- explicit Thread state and execution policy;
- visible progress, artifacts, and decisions;
- machine-generated test and build evidence;
- independent verification where appropriate;
- clear unresolved findings and user-controlled approvals.

## User experience

People should be able to describe a goal, follow its Thread, answer
questions or approvals when needed, and review the completed work without
manually coordinating every execution detail. Work remains attributable to its
Space and Thread, with current state and evidence available for later
review.
