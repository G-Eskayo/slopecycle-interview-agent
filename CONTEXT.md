# SlopeCycle Interview Analyst — Context Glossary

Domain terms only. No implementation details — see `docs/adr/` for decisions and rationale.

## Sources

- **Source**: one file a teammate puts in the Inbox folder: interview notes, a transcript, or an audio recording of an interview. A Source is never edited or deleted by the agent.
- **Inbox**: the single shared Drive folder the agent reads from. Anything outside it does not exist to the agent.
- **Source revision**: one version of a Source. Editing a Doc makes a new revision; uploading the same file again does not.
- **Transcript**: the speaker-labelled, timestamped text the agent produces from an audio Source. It is the raw text the audio contains, never a cleaned-up rewrite, because Evidence must quote it exactly.

## Interviews and people

- **Interview**: one conversation between a teammate and one Respondent, recorded in one Source. One Interview is one row.
- **Respondent**: the person being interviewed, referred to by a label, never by name unless the team's log already requires it.
- **Parent interview**: an Interview with a parent or guardian about their own family's buying. Only these count toward parent statistics.
- **Expert interview**: an Interview with someone speaking from their trade (shop owner, coach, rental operator). Their opinion about parents is not a parent's behaviour.
- **Interviewer**: the teammate who ran the Interview. What the Interviewer says (questions, suggested prices) is never treated as the Respondent's answer.

## Findings

- **Evidence**: one exact excerpt from a Source or Transcript backing one claim, with where it sits (line, paragraph or timestamp). An excerpt from rough notes is an **interviewer note**, not a quote.
- **Not provided**: the Respondent did not say. Not provided is never zero, no, or false.
- **Conditional interest**: interest in renting that depends on something ("if swaps are free"). It is not a yes and not demand.
- **Calculated value**: a number the agent worked out (e.g. per-child average), always labelled as calculated and never presented as something the Respondent said.
- **Hypothesis**: a belief the team has written down and supplied. The agent never invents one.

## Running

- **Run**: one attempt to process one Source revision. Every Run ends completed, needs-review, or failed, and is recorded in the Run Log.
- **Needs review**: the agent wrote the Interview but found something a person must check (conflicting statements, unclear spending, missing key fields).
- **Override**: a correction a founder typed by hand. The agent never overwrites an Override.
- **Processor Mac**: the one team computer that does the processing. Sources wait in the Inbox until it is awake.
