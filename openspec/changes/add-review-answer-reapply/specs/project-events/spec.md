## ADDED Requirements

### Requirement: Answer events name a re-applied source
Every `answer_recorded` event's `data` SHALL have `reapplied_from_head`: the head of the earlier answer a re-applied answer copied, and null for an answer given directly. A reapply of several items SHALL record one `answer_recorded` event per stored answer.

#### Scenario: Re-applied answer event
- **WHEN** an approval from head `H1` is re-applied at head `H2`
- **THEN** the `answer_recorded` event has `head` `H2`, `answer` `approve` and `reapplied_from_head` `H1`

#### Scenario: Direct answer event
- **WHEN** an answer is given directly through the answer route
- **THEN** its `answer_recorded` event has `reapplied_from_head` null
