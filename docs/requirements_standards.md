## The Requirements Language Layer

**EARS (Easy Approach to Requirements Syntax)** gives you a constrained-natural-language template that makes each requirement individually testable and linkable. Five patterns cover almost everything:

- Ubiquitous
- Event-driven
- State-driven
- Optional-feature
- Unwanted-behavior

Each statement gets an ID and can be referenced from tests, design docs, and code. For UI specifically you write things like:

> When the user submits the form with an invalid email, the system shall display error message E-204 adjacent to the email field.62366-1 (usability engineering), IEC 62304 (software lifecycle), FDA Human Factors guidance |
> | Aviation | DO-178C, DO-330 (tools), ARP 4754A (system level), ARINC 661 (cockpit displays, itself a UI spec standard) |
> | Automotive | ISO 26262, ISO 21448 (SOTIF) |
> | Rail | EN 50128 |

For medical devices you produce a Use Specification, Use Scenarios, and a Usability Engineering File that traces hazards through UI mitigations. For automotive, UI requirements feed into HARA and ASIL allocation.

## The Practical Pattern That Actually Gets Used

Stable IDs everywhere:

- Every UI element has an ID (`btn.submit.payment`)
- Every requirement has an ID (`REQ-UI-0142`)
- Every screen has an ID (`SCR-CHECKOUT-03`)
- Every test has an ID

Requirements are written in EARS, stored in ReqIF or Markdown with structured frontmatter, and linked bidirectionally. A traceability matrix, auto-generated and never hand-maintained, shows requirement to design to code to test. Mockups are referenced from requirements by element ID, so the mockup can change visually without breaking the requirement text, as long as the ID is preserved.

## Concrete Recommendation

Write requirements in EARS. Store them as Markdown with IDs in your repo, or in ReqIF if your auditor needs it. Use Sphinx-Needs or StrictDoc to generate the traceability artifacts. Reference mockup elements by stable ID.

That's atomic, testable, traceable.

## The Container Layer

**ReqIF (Requirements Interchange Format)** is the OMG standard for exchanging structured requirements between tools. XML-based, tool-agnostic, supports attributes, links, and hierarchy. DOORS, Polarion, Jama, and codeBeamer all import and export it. If you want your text to survive tool changes and to be diffable in source control, ReqIF is the format.

A simpler convention is growing in the embedded world: requirements written as Markdown with structured IDs, linked via tooling like **Sphinx-Needs** or **StrictDoc**, both of which generate traceability matrices from plain text.

## The Framework Layer

**ISO/IEC/IEEE 29148** defines the structure of a Software Requirements Specification, including what a good requirement looks like (verifiable, unambiguous, traceable, etc.). It supersedes the old IEEE 830. It tells you what sections an SRS has, not what your UI must do.

## UI-Specific Modeling

**IFML (Interaction Flow Modeling Language)**, an OMG standard, models view containers, view components, events, and navigation flow. It's the closest thing to a formal UI specification language. UsiXML exists too but has less industry uptake.

Most regulated shops do not use IFML and instead pair textual requirements with annotated mockups, where each interactive element has a stable ID that requirements reference by name.

## The Domain Overlay

This is usually what "regulated" means in practice.

| Domain          | Standards |
| --------------- | --------- |
| Medical devices | IEC       |
